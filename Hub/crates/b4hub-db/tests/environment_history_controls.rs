//! Native controls for the pending, public Hub 18 preservation path.
//! The original migrate.rs tests and frozen migrations are deliberately unchanged.

mod common;

use std::error::Error as StdError;
use std::fmt;
use std::time::{Duration, Instant};

use b4hub_db::{orgs, Db};
use sha2::{Digest, Sha384};
use sqlx::postgres::PgPoolOptions;
use sqlx::{Connection, PgConnection, PgPool};
use tokio::task::JoinHandle;
use uuid::Uuid;

type Result<T = ()> = std::result::Result<T, Failure>;
type Runner = JoinHandle<std::result::Result<(), b4hub_db::Error>>;

// Retain primary and cleanup causes without printing native DETAIL/opaque fixtures in test Debug.
struct Failure {
    stage: &'static str,
    cause: Option<Box<dyn StdError + Send + Sync>>,
    secondary: Vec<Failure>,
}
impl Failure {
    fn invariant(stage: &'static str) -> Self {
        Self {
            stage,
            cause: None,
            secondary: Vec::new(),
        }
    }
    fn caused(stage: &'static str, cause: impl StdError + Send + Sync + 'static) -> Self {
        Self {
            stage,
            cause: Some(Box::new(cause)),
            secondary: Vec::new(),
        }
    }
}
impl fmt::Debug for Failure {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ControlFailure")
            .field("stage", &self.stage)
            .field("secondary", &self.secondary)
            .finish_non_exhaustive()
    }
}
impl fmt::Display for Failure {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.stage)
    }
}
impl StdError for Failure {
    fn source(&self) -> Option<&(dyn StdError + 'static)> {
        self.cause
            .as_deref()
            .map(|error| error as &(dyn StdError + 'static))
    }
}
impl From<sqlx::Error> for Failure {
    fn from(error: sqlx::Error) -> Self {
        Self::caused("native fixture SQL", error)
    }
}
impl From<b4hub_db::Error> for Failure {
    fn from(error: b4hub_db::Error) -> Self {
        Self::caused("public migration runner", error)
    }
}
impl From<std::io::Error> for Failure {
    fn from(error: std::io::Error) -> Self {
        Self::caused("owned prefix scratch", error)
    }
}
impl From<sqlx::migrate::MigrateError> for Failure {
    fn from(error: sqlx::migrate::MigrateError) -> Self {
        Self::caused("native prefix migration", error)
    }
}
impl From<url::ParseError> for Failure {
    fn from(error: url::ParseError) -> Self {
        Self::caused("fixture URL shape", error)
    }
}
fn require(condition: bool, stage: &'static str) -> Result {
    if condition {
        Ok(())
    } else {
        Err(Failure::invariant(stage))
    }
}
fn merge(first: Result, next: Result) -> Result {
    match (first, next) {
        (Ok(()), result) | (result, Ok(())) => result,
        (Err(mut primary), Err(secondary)) => {
            primary.secondary.push(secondary);
            Err(primary)
        }
    }
}
fn ident(value: &str) -> String {
    format!("\"{}\"", value.replace('"', "\"\""))
}
fn tagged(url: &str, name: &str) -> Result<String> {
    let mut url = url::Url::parse(url)?;
    let preserved: Vec<(String, String)> = url
        .query_pairs()
        .filter(|(key, _)| key != "application_name")
        .map(|(key, value)| (key.into_owned(), value.into_owned()))
        .collect();
    url.set_query(None);
    url.query_pairs_mut().extend_pairs(preserved);
    url.query_pairs_mut().append_pair("application_name", name);
    Ok(url.to_string())
}
fn checksum18() -> String {
    format!(
        "{:x}",
        Sha384::digest(include_bytes!("../migrations/0018_environments.sql"))
    )
}
async fn no_backends(pool: &PgPool, names: &[String]) -> Result {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let absent: bool = sqlx::query_scalar("SELECT NOT EXISTS(SELECT 1 FROM pg_stat_activity WHERE datname=current_database() AND application_name=ANY($1::text[]))")
            .bind(names).fetch_one(pool).await?;
        if absent {
            return Ok(());
        }
        require(
            Instant::now() < deadline,
            "scoped closed connection backend remains",
        )?;
        tokio::task::yield_now().await;
    }
}

#[derive(Clone, Copy)]
struct Flags(bool, bool);
const TT: Flags = Flags(true, true);
const TF: Flags = Flags(true, false);
const FF: Flags = Flags(false, false);
const FT: Flags = Flags(false, true);

struct Scratch(std::path::PathBuf);
impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}
async fn prefix17(pool: &PgPool) -> Result {
    let scratch =
        Scratch(std::env::temp_dir().join(format!("b4hub-migrations-{}", Uuid::new_v4().simple())));
    std::fs::create_dir(&scratch.0)?;
    let source = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("migrations");
    for entry in std::fs::read_dir(source)? {
        let path = entry?.path();
        let name = path
            .file_name()
            .and_then(|name| name.to_str())
            .ok_or_else(|| Failure::invariant("prefix filename"))?;
        if name < "0018" && name.ends_with(".sql") {
            std::fs::copy(&path, scratch.0.join(name))?;
        }
    }
    sqlx::migrate::Migrator::new(scratch.0.as_path())
        .await?
        .run(pool)
        .await?;
    Ok(())
}

struct Fixture {
    pool: PgPool,
    owner: String,
    owner_url: String,
    app_url: String,
    orgs: [Uuid; 2],
    users: [Uuid; 2],
    devices: [Uuid; 2],
    changes: Flags,
    clocks: Flags,
}
impl Fixture {
    async fn new(pool: &PgPool, changes: Flags, clocks: Flags) -> Result<Self> {
        let owner = format!("history_owner_{}", Uuid::new_v4().simple());
        sqlx::query(&format!(
            "CREATE ROLE {} LOGIN CREATEROLE NOSUPERUSER NOBYPASSRLS PASSWORD 'owner-pw'",
            ident(&owner)
        ))
        .execute(pool)
        .await?;
        sqlx::raw_sql("DO $$ BEGIN CREATE ROLE b4hub_app LOGIN NOSUPERUSER NOBYPASSRLS PASSWORD 'pw-test'; EXCEPTION WHEN duplicate_object OR unique_violation THEN NULL; END $$;")
            .execute(pool).await?;
        sqlx::query(&format!(
            "GRANT b4hub_app TO {} WITH ADMIN OPTION",
            ident(&owner)
        ))
        .execute(pool)
        .await?;
        sqlx::query(&format!(
            "GRANT USAGE, CREATE ON SCHEMA public TO {}",
            ident(&owner)
        ))
        .execute(pool)
        .await?;
        let database: String = sqlx::query_scalar("SELECT current_database()")
            .fetch_one(pool)
            .await?;
        sqlx::query(&format!(
            "GRANT CREATE ON DATABASE {} TO {}",
            ident(&database),
            ident(&owner)
        ))
        .execute(pool)
        .await?;
        let owner_url = common::url_as(pool, &owner, "owner-pw");
        let prefix_name = format!("h18_prefix_{}", Uuid::new_v4().simple());
        let owner_pool = PgPoolOptions::new()
            .max_connections(1)
            .connect(&tagged(&owner_url, &prefix_name)?)
            .await?;
        let migrated = async {
            prefix17(&owner_pool).await?;
            let no_tenant: bool = sqlx::query_scalar("SELECT current_user=$1 AND NULLIF(current_setting('b4hub.org_id',true),'') IS NULL")
                .bind(&owner).fetch_one(&owner_pool).await?;
            require(no_tenant, "operator has no tenant context")
        }.await;
        owner_pool.close().await;
        merge(migrated, no_backends(pool, &[prefix_name]).await)?;
        let actual: (bool, bool, bool) = sqlx::query_as(
            "SELECT rolsuper,rolbypassrls,rolcreaterole FROM pg_roles WHERE rolname=$1",
        )
        .bind(&owner)
        .fetch_one(pool)
        .await?;
        require(
            actual == (false, false, true),
            "genuine non-super owner attributes",
        )?;
        let ordinary_app: (bool, bool) =
            sqlx::query_as("SELECT rolsuper,rolbypassrls FROM pg_roles WHERE rolname='b4hub_app'")
                .fetch_one(pool)
                .await?;
        require(
            ordinary_app == (false, false),
            "genuine ordinary application role",
        )?;
        let owned: bool = sqlx::query_scalar("SELECT count(*)=9 AND bool_and(pg_get_userbyid(c.relowner)=$1) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relname IN ('projects','projectFolders','threads','connections','changes','column_clocks','projects_by_user','projectFolders_by_user','_sqlx_migrations')")
            .bind(&owner).fetch_one(pool).await?;
        require(
            owned,
            "prefix objects must be created by the operator, never reassigned",
        )?;
        let mut org_ids = Vec::new();
        let mut user_ids = Vec::new();
        let mut device_ids = Vec::new();
        for (slug, user) in [("history-one", "one"), ("history-two", "two")] {
            let seed = orgs::seed(
                &Db { pool: pool.clone() },
                slug,
                "Fixture",
                user,
                user,
                &format!("{user}@example.test"),
            )
            .await?;
            let device: Uuid = sqlx::query_scalar("INSERT INTO devices(id,org_id,user_id,name,platform) VALUES(gen_random_uuid(),$1,$2,'Fixture','macos') RETURNING id")
                .bind(seed.org_id).bind(seed.user_id).fetch_one(pool).await?;
            org_ids.push(seed.org_id);
            user_ids.push(seed.user_id);
            device_ids.push(device);
        }
        let fixture = Self {
            pool: pool.clone(),
            owner,
            owner_url,
            app_url: common::app_url(pool, "pw-test"),
            orgs: [org_ids[0], org_ids[1]],
            users: [user_ids[0], user_ids[1]],
            devices: [device_ids[0], device_ids[1]],
            changes,
            clocks,
        };
        fixture.seed().await?;
        for (table, Flags(enabled, forced)) in [("changes", changes), ("column_clocks", clocks)] {
            sqlx::raw_sql(&format!("ALTER TABLE public.{table} {} ROW LEVEL SECURITY; ALTER TABLE public.{table} {} ROW LEVEL SECURITY;",
                if enabled { "ENABLE" } else { "DISABLE" }, if forced { "FORCE" } else { "NO FORCE" }))
                .execute(pool).await?;
        }
        fixture.check_flags().await?;
        Ok(fixture)
    }
    async fn seed(&self) -> Result {
        for i in 0..2 {
            for sql in [
                "INSERT INTO projects(id,name,org_id,user_id,device_id,owner_device_id) VALUES('p1','before',$1,$2,$3,$3)",
                "INSERT INTO \"projectFolders\"(id,\"projectId\",org_id,user_id,device_id,owner_device_id) VALUES('f1','p1',$1,$2,$3,$3)",
                "INSERT INTO threads(id,\"projectId\",org_id,user_id,device_id,owner_device_id) VALUES('t1','p1',$1,$2,$3,$3)",
                "INSERT INTO connections(id,\"projectId\",org_id,user_id,device_id,owner_device_id) VALUES('c1','p1',$1,$2,$3,$3)",
                "INSERT INTO column_clocks(org_id,\"table\",row_id,\"column\",hlc) SELECT $1,t,r,c,'clock' FROM (VALUES('projects','p1','name'),('threads','t1','projectId')) s(t,r,c) WHERE $2::uuid IS NOT NULL AND $3::uuid IS NOT NULL",
            ] {
                sqlx::query(sql).bind(self.orgs[i]).bind(self.users[i]).bind(self.devices[i]).execute(&self.pool).await?;
            }
            sqlx::query(r#"
INSERT INTO changes(org_id,hub_seq,device_id,device_seq,user_id,wall,"table",row_id,op,"column",value,hlc,value_bytes)
SELECT $1,s.seq,$3,s.seq,$2,s.seq,s.tbl,s.row_id,s.op,s.col,s.val,'control-'||s.seq::text,
 CASE WHEN s.seq>=4242 THEN (7000+$4)::integer ELSE octet_length(s.val::text) END
FROM (VALUES
 (1::bigint,'projects','p1','insert',NULL::text,'{"id":"p1","name":"before"}'::jsonb),
 (2,'projectFolders','f1','insert',NULL,'{"id":"f1","projectId":"p1"}'::jsonb),
 (3,'threads','t1','insert',NULL,'{"id":"t1","projectId":"p1"}'::jsonb),
 (4,'threads','t1','update','projectId','"p1"'::jsonb),
 (5,'connections','c1','insert',NULL,'{"id":"c1","projectId":"p1"}'::jsonb),
 (4242,'displayItems','opaque-same','update','payload',jsonb_build_object('projectId',$5::text,'environmentId',$6::text,'nested','{"projectId":"inside"}'::jsonb,'n',123456789012345678901234567890.1234567890123456789::numeric)),
 (4243,'displayItems','opaque-single','update','payload','{"projectId":"external"}'::jsonb),
 (4244,'displayItems','opaque-nested','update','payload','{"nested":{"projectId":"inside"}}'::jsonb),
 (4245,'displayItems','opaque-array','update','payload','[{"projectId":"external"}]'::jsonb),
 (4246,'connections','opaque-capabilities','update','capabilities','{"projectId":"external","environmentId":"keep"}'::jsonb)
) s(seq,tbl,row_id,op,col,val)
"#).bind(self.orgs[i]).bind(self.users[i]).bind(self.devices[i]).bind(i as i32)
                .bind(if i == 0 { "external-one" } else { "external-two" })
                .bind(if i == 0 { "keep-one" } else { "keep-two" }).execute(&self.pool).await?;
        }
        let collision: bool = sqlx::query_scalar("SELECT count(*)=2 AND count(DISTINCT org_id)=2 AND count(DISTINCT value::text)=2 AND count(DISTINCT value_bytes)=2 FROM changes WHERE hub_seq=4242")
            .fetch_one(&self.pool).await?;
        require(
            collision,
            "two organizations must share a sequence with distinct native originals",
        )
    }
    async fn check_flags(&self) -> Result {
        for (table, Flags(enabled, forced)) in
            [("changes", self.changes), ("column_clocks", self.clocks)]
        {
            let actual: (bool, bool) = sqlx::query_as(
                "SELECT relrowsecurity,relforcerowsecurity FROM pg_class WHERE oid=$1::regclass",
            )
            .bind(format!("public.{table}"))
            .fetch_one(&self.pool)
            .await?;
            require(
                actual == (enabled, forced),
                "per-table RLS flags changed or were swapped",
            )?;
        }
        Ok(())
    }
    fn tag(&self, suffix: &str) -> String {
        format!("h18_{suffix}_{}", Uuid::new_v4().simple())
    }
    async fn no_tagged_backends(&self, names: &[String]) -> Result {
        no_backends(&self.pool, names).await
    }
    async fn run(&self, suffix: &str) -> Result<std::result::Result<(), b4hub_db::Error>> {
        let name = self.tag(suffix);
        let outcome = b4hub_db::migrate::run(&tagged(&self.owner_url, &name)?, &self.app_url).await;
        self.no_tagged_backends(&[name]).await?;
        Ok(outcome)
    }
}

#[derive(PartialEq, Eq)]
struct Snapshot {
    rows: Vec<(String, String)>,
    rendered: Vec<(String, String, Option<String>, i32)>,
    catalog: String,
    sequences: Vec<(String, String, bool)>,
}
async fn snapshot(conn: &mut PgConnection) -> Result<Snapshot> {
    let tables: Vec<String> = sqlx::query_scalar("SELECT c.relname::text FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relkind='r' ORDER BY c.relname::text COLLATE \"C\"")
        .fetch_all(&mut *conn).await?;
    let mut rows = Vec::new();
    for table in tables {
        let value: String = sqlx::query_scalar(&format!("SELECT COALESCE(jsonb_agg(v ORDER BY v::text COLLATE \"C\"),'[]'::jsonb)::text FROM(SELECT to_jsonb(t) v FROM public.{} t)s", ident(&table)))
            .fetch_one(&mut *conn).await?;
        rows.push((table, value));
    }
    let rendered = sqlx::query_as("SELECT org_id::text,hub_seq::text,value::text,value_bytes FROM public.changes ORDER BY org_id,hub_seq")
        .fetch_all(&mut *conn).await?;
    let catalog: String = sqlx::query_scalar(r#"
SELECT jsonb_build_object(
 'relations',(SELECT jsonb_agg(jsonb_build_array(c.oid::bigint,c.relname,c.relkind,pg_get_userbyid(c.relowner),c.relrowsecurity,c.relforcerowsecurity,c.relacl) ORDER BY c.oid) FROM pg_class c WHERE c.relnamespace='public'::regnamespace),
 'attributes',(SELECT jsonb_agg(jsonb_build_array(a.attrelid::bigint,a.attnum,a.attname,a.atttypid::bigint,a.atttypmod,a.attcollation::bigint,a.attnotnull,a.attidentity,a.attgenerated,pg_get_expr(d.adbin,d.adrelid)) ORDER BY a.attrelid,a.attnum) FROM pg_attribute a JOIN pg_class c ON c.oid=a.attrelid LEFT JOIN pg_attrdef d ON d.adrelid=a.attrelid AND d.adnum=a.attnum WHERE c.relnamespace='public'::regnamespace AND a.attnum>0 AND NOT a.attisdropped),
 'constraints',(SELECT jsonb_agg(jsonb_build_array(oid::bigint,conrelid::bigint,conname,pg_get_constraintdef(oid)) ORDER BY oid) FROM pg_constraint WHERE connamespace='public'::regnamespace),
 'indexes',(SELECT jsonb_agg(jsonb_build_array(i.indexrelid::bigint,pg_get_indexdef(i.indexrelid)) ORDER BY i.indexrelid) FROM pg_index i JOIN pg_class c ON c.oid=i.indexrelid WHERE c.relnamespace='public'::regnamespace),
 'policies',(SELECT jsonb_agg(jsonb_build_array(p.oid::bigint,p.polrelid::bigint,p.polname,p.polcmd,p.polpermissive,p.polroles,pg_get_expr(p.polqual,p.polrelid),pg_get_expr(p.polwithcheck,p.polrelid)) ORDER BY p.oid) FROM pg_policy p JOIN pg_class c ON c.oid=p.polrelid WHERE c.relnamespace='public'::regnamespace),
 'triggers',(SELECT jsonb_agg(jsonb_build_array(t.oid::bigint,pg_get_triggerdef(t.oid),t.tgenabled) ORDER BY t.oid) FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid WHERE c.relnamespace='public'::regnamespace AND NOT t.tgisinternal),
 'functions',(SELECT jsonb_agg(jsonb_build_array(oid::bigint,proname,prosrc,proconfig,proacl,proowner::bigint) ORDER BY oid) FROM pg_proc WHERE pronamespace='public'::regnamespace),
 'sequence_parameters',(SELECT jsonb_agg(to_jsonb(s) ORDER BY s.seqrelid) FROM pg_sequence s JOIN pg_class c ON c.oid=s.seqrelid WHERE c.relnamespace='public'::regnamespace)
)::text
"#).fetch_one(&mut *conn).await?;
    let names: Vec<String> = sqlx::query_scalar("SELECT relname::text FROM pg_class WHERE relnamespace='public'::regnamespace AND relkind='S' AND relname<>'control_stage_probe' ORDER BY relname::text COLLATE \"C\"")
        .fetch_all(&mut *conn).await?;
    let mut sequences = Vec::new();
    for name in names {
        let (last, called): (String, bool) = sqlx::query_as(&format!(
            "SELECT last_value::text,is_called FROM public.{}",
            ident(&name)
        ))
        .fetch_one(&mut *conn)
        .await?;
        sequences.push((name, last, called));
    }
    Ok(Snapshot {
        rows,
        rendered,
        catalog,
        sequences,
    })
}
async fn remember_opaque(conn: &mut PgConnection) -> Result {
    sqlx::raw_sql("CREATE TEMP TABLE control_opaque_before AS SELECT c.*,c.value::text AS rendered FROM public.changes c WHERE row_id LIKE 'opaque-%';")
        .execute(&mut *conn).await?;
    let n: i64 = sqlx::query_scalar("SELECT count(*) FROM control_opaque_before")
        .fetch_one(conn)
        .await?;
    require(n == 10, "ten exact opaque beforeimages")
}
async fn original_ledger(conn: &mut PgConnection) -> Result<Vec<String>> {
    Ok(sqlx::query_scalar(
        "SELECT to_jsonb(m)::text FROM public._sqlx_migrations m WHERE version<18 ORDER BY version",
    )
    .fetch_all(conn)
    .await?)
}
// Later migrations may follow 18; the ledger must still be contiguous from 1 and reach 18.
async fn complete_ledger(conn: &mut PgConnection) -> Result {
    let versions: Vec<i64> = sqlx::query_scalar(
        "SELECT version FROM public._sqlx_migrations WHERE success ORDER BY version",
    )
    .fetch_all(&mut *conn)
    .await?;
    let head = versions.len() as i64;
    require(
        head == 23 && versions == (1..=head).collect::<Vec<i64>>(),
        "one complete legitimate ledger through twenty-one",
    )?;
    let rows: i64 = sqlx::query_scalar("SELECT count(*) FROM public._sqlx_migrations")
        .fetch_one(&mut *conn)
        .await?;
    require(rows == head, "no extra or failed ledger rows")?;
    let checksum: bool = sqlx::query_scalar("SELECT checksum=decode($1,'hex') AND execution_time>=0 FROM public._sqlx_migrations WHERE version=18")
        .bind(checksum18()).fetch_one(&mut *conn).await?;
    require(
        checksum,
        "original frozen checksum and native execution time",
    )
}
async fn positive(f: &Fixture, oracle: &mut PgConnection) -> Result {
    let preserved: bool = sqlx::query_scalar("SELECT NOT EXISTS(SELECT 1 FROM control_opaque_before b LEFT JOIN public.changes a USING(org_id,hub_seq) WHERE a.org_id IS NULL OR to_jsonb(a) IS DISTINCT FROM (to_jsonb(b)-'rendered') OR a.value::text IS DISTINCT FROM b.rendered)")
        .fetch_one(&mut *oracle).await?;
    require(
        preserved,
        "composite-key opaque full rows/text/stored bytes",
    )?;
    let structural: bool = sqlx::query_scalar(r#"
SELECT (SELECT count(*) FROM environments WHERE id='p1' AND name='before')=2
 AND (SELECT count(*) FROM "environmentFolders" WHERE id='f1' AND "environmentId"='p1')=2
 AND (SELECT count(*) FROM threads WHERE id='t1' AND "environmentId"='p1')=2
 AND (SELECT count(*) FROM connections WHERE id='c1' AND "environmentId"='p1')=2
 AND (SELECT count(*) FROM changes)=20
 AND (SELECT count(*) FROM changes WHERE op='insert' AND "table" IN('environmentFolders','threads','connections') AND value->>'environmentId'='p1' AND value_bytes=octet_length(value::text))=6
 AND (SELECT count(*) FROM changes WHERE "table"='threads' AND op='update' AND "column"='environmentId' AND value='"p1"'::jsonb)=2
 AND NOT EXISTS(SELECT 1 FROM changes WHERE "table" IN('projects','projectFolders') OR "column"='projectId')
 AND (SELECT count(*) FROM column_clocks WHERE "table"='environments' AND row_id='p1' AND "column"='name')=2
 AND (SELECT count(*) FROM column_clocks WHERE "table"='threads' AND row_id='t1' AND "column"='environmentId')=2
 AND NOT EXISTS(SELECT 1 FROM column_clocks WHERE "table" IN('projects','projectFolders') OR "column"='projectId')
"#).fetch_one(&mut *oracle).await?;
    require(structural, "exact live/feed/clock structural renames")?;
    complete_ledger(oracle).await?;
    f.check_flags().await
}
async fn app_isolation(f: &Fixture) -> Result {
    let mut app = PgConnection::connect(&f.app_url).await?;
    let outcome = async {
        let absent: i64 = sqlx::query_scalar("SELECT count(*) FROM changes")
            .fetch_one(&mut app)
            .await?;
        let clocks_absent: i64 = sqlx::query_scalar("SELECT count(*) FROM column_clocks")
            .fetch_one(&mut app)
            .await?;
        require(
            absent == 0 && clocks_absent == 0,
            "app has no implicit tenant on either enabled table",
        )?;
        let mut tx = app.begin().await?;
        let result = async {
            sqlx::query("SELECT set_config('b4hub.org_id',$1,true)")
                .bind(f.orgs[0].to_string())
                .execute(&mut *tx)
                .await?;
            let isolated: bool =
                sqlx::query_scalar("SELECT count(*)=10 AND bool_and(org_id=$1) FROM changes")
                    .bind(f.orgs[0])
                    .fetch_one(&mut *tx)
                    .await?;
            let clocks_isolated: bool =
                sqlx::query_scalar("SELECT count(*)=2 AND bool_and(org_id=$1) FROM column_clocks")
                    .bind(f.orgs[0])
                    .fetch_one(&mut *tx)
                    .await?;
            require(
                isolated && clocks_isolated,
                "app sees only its selected organization on each enabled table",
            )
        }
        .await;
        let rolled = tx.rollback().await.map_err(Failure::from);
        merge(result, rolled)
    }
    .await;
    merge(outcome, app.close().await.map_err(Failure::from))
}
async fn owner_case(pool: &PgPool, changes: Flags, clocks: Flags, isolate: bool) -> Result {
    let f = Fixture::new(pool, changes, clocks).await?;
    let mut oracle = pool.acquire().await?;
    remember_opaque(&mut oracle).await?;
    let before_ledger = original_ledger(&mut oracle).await?;
    require(before_ledger.len() == 17, "genuine prefix seventeen ledger")?;
    let result = async {
        f.run("owner").await??;
        positive(&f, &mut oracle).await?;
        let original = original_ledger(&mut oracle).await?;
        require(
            original == before_ledger,
            "prefix ledger checksums and full timing fields preserved",
        )?;
        if isolate {
            app_isolation(&f).await?;
        }
        let after = snapshot(&mut oracle).await?;
        f.run("again").await??;
        require(
            snapshot(&mut oracle).await? == after,
            "historical rows/catalog/ledger are idempotent",
        )
    }
    .await;
    drop(oracle);
    result
}

fn safe_guard(error: b4hub_db::Error) -> Result {
    let exact = matches!(&error, b4hub_db::Error::Migrate(sqlx::migrate::MigrateError::ExecuteMigration(sqlx::Error::Protocol(message), 18)) if message == "environment history preservation failed");
    let mut private = format!("{error}\n{error:?}");
    let mut source = StdError::source(&error);
    while let Some(cause) = source {
        private.push_str(&format!("\n{cause}\n{cause:?}"));
        source = cause.source();
    }
    let safe = exact
        && !private.contains("HISTORY_PRIVATE_CANARY")
        && !private.contains("external-one")
        && !private.contains("23514")
        && !private.contains("control_fault")
        && !private.contains("CONTEXT");
    if safe {
        Ok(())
    } else {
        Err(Failure::caused("guard error privacy/shape", error))
    }
}

#[derive(Clone, Copy)]
enum Fault {
    Restore,
    Commit,
    Gate(i32, i32),
    ChangesCollision,
}
async fn install_fault(f: &Fixture, fault: Fault) -> Result {
    if matches!(fault, Fault::Commit | Fault::Gate(_, _)) {
        return install_ledger_deferred_fault(f, fault).await;
    }
    let Flags(ce, cf) = f.changes;
    let Flags(ke, kf) = f.clocks;
    let tail = match fault {
        Fault::Restore | Fault::Commit | Fault::ChangesCollision => "RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='HISTORY_PRIVATE_CANARY', DETAIL=NEW.value::text;".to_owned(),
        Fault::Gate(a, b) => format!("PERFORM pg_advisory_xact_lock({a},{b}); RETURN NEW;"),
    };
    let constraint = !matches!(fault, Fault::Restore);
    let sql = format!(
        r#"
CREATE SEQUENCE public.control_stage_probe;
GRANT USAGE,SELECT ON SEQUENCE public.control_stage_probe TO {owner};
CREATE FUNCTION public.control_fault() RETURNS trigger LANGUAGE plpgsql AS $body$
BEGIN
 IF to_regclass('public.environments') IS NULL OR to_regclass('public.projects') IS NOT NULL
 OR NOT EXISTS(SELECT 1 FROM public._sqlx_migrations WHERE version=18 AND success AND checksum=decode('{checksum}','hex') AND execution_time>=0)
 OR NEW.value IS DISTINCT FROM jsonb_build_object('projectId','external-one','environmentId','keep-one','nested','{{"projectId":"inside"}}'::jsonb,'n',123456789012345678901234567890.1234567890123456789::numeric)
 OR NEW.value::text IS DISTINCT FROM jsonb_build_object('projectId','external-one','environmentId','keep-one','nested','{{"projectId":"inside"}}'::jsonb,'n',123456789012345678901234567890.1234567890123456789::numeric)::text
 OR NEW.value_bytes<>7000
 THEN RAISE EXCEPTION 'fixture did not reach post-delegate restoration'; END IF;
 {flag_checks}
 PERFORM nextval('public.control_stage_probe');
 {tail}
END $body$;
CREATE {constraint_word} TRIGGER control_stage_trigger {timing} {event} ON public.changes
 {deferred} FOR EACH ROW
 WHEN(NEW.org_id='{org}'::uuid AND NEW.hub_seq=4242 AND NOT(OLD.value ? 'projectId') AND NEW.value ? 'projectId' AND NEW.value ? 'environmentId')
 EXECUTE FUNCTION public.control_fault();
"#,
        owner = ident(&f.owner),
        checksum = checksum18(),
        org = f.orgs[0],
        tail = tail,
        constraint_word = if constraint { "CONSTRAINT" } else { "" },
        timing = if constraint { "AFTER" } else { "BEFORE" },
        event = if constraint {
            "UPDATE"
        } else {
            "UPDATE OF value,value_bytes"
        },
        deferred = if constraint {
            "DEFERRABLE INITIALLY DEFERRED"
        } else {
            ""
        },
        flag_checks = if constraint {
            format!("IF NOT EXISTS(SELECT 1 FROM pg_class WHERE oid='public.changes'::regclass AND relrowsecurity={ce} AND relforcerowsecurity={cf}) OR NOT EXISTS(SELECT 1 FROM pg_class WHERE oid='public.column_clocks'::regclass AND relrowsecurity={ke} AND relforcerowsecurity={kf}) THEN RAISE EXCEPTION 'fixture did not reach restored flags at outer commit'; END IF;")
        } else {
            String::new()
        }
    );
    sqlx::raw_sql(&sql).execute(&f.pool).await?;
    let shape: (bool, bool, bool) = sqlx::query_as("SELECT tgconstraint<>0,tgdeferrable,tginitdeferred FROM pg_trigger WHERE tgrelid='public.changes'::regclass AND tgname='control_stage_trigger'")
        .fetch_one(&f.pool).await?;
    require(
        shape == (constraint, constraint, constraint),
        "exact native constraint/deferred trigger state",
    )
}
// The ledger is not ALTERed by the guard. Its initially-deferred INSERT event
// can therefore observe physical outer COMMIT after all row/flag restoration.
// The definer is an explicit fixture oracle: production owners remain non-super.
async fn install_ledger_deferred_fault(f: &Fixture, fault: Fault) -> Result {
    let Flags(ce, cf) = f.changes;
    let Flags(ke, kf) = f.clocks;
    let tail = match fault {
        Fault::Commit => "RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='HISTORY_PRIVATE_CANARY', DETAIL=canary_value;".to_owned(),
        Fault::Gate(a, b) => format!("PERFORM pg_catalog.pg_advisory_xact_lock({a},{b}); RETURN NEW;"),
        _ => return Err(Failure::invariant("ledger deferred mode")),
    };
    let sql = format!(
        r#"
CREATE SEQUENCE public.control_stage_probe;
GRANT USAGE,SELECT ON SEQUENCE public.control_stage_probe TO {owner};
CREATE FUNCTION public.control_fault() RETURNS trigger LANGUAGE plpgsql
 SECURITY DEFINER SET search_path=pg_catalog AS $body$
DECLARE
 ledger record;
 opaque record;
 expected_value jsonb;
 canary_value text;
BEGIN
 IF TG_RELID<>'public._sqlx_migrations'::pg_catalog.regclass OR TG_OP<>'INSERT'
 OR NEW.version<>18 OR NOT NEW.success OR NEW.checksum IS DISTINCT FROM pg_catalog.decode('{checksum}','hex')
 THEN RAISE EXCEPTION 'fixture did not receive authentic ledger insert eighteen'; END IF;
 -- NEW is the INSERT tuple with execution_time=-1; inspect the current row,
 -- updated by SQLx only after its tracked nested SAVEPOINT has been released.
 SELECT version,description,success,checksum,execution_time INTO STRICT ledger
 FROM public._sqlx_migrations WHERE version=18;
 IF NOT ledger.success OR ledger.description IS DISTINCT FROM 'environments'
 OR ledger.checksum IS DISTINCT FROM pg_catalog.decode('{checksum}','hex') OR ledger.execution_time<0
 OR pg_catalog.to_regclass('public.environments') IS NULL OR pg_catalog.to_regclass('public.projects') IS NOT NULL
 THEN RAISE EXCEPTION 'fixture did not reach post-delegate ledger state'; END IF;
 IF NOT EXISTS(SELECT 1 FROM pg_catalog.pg_class WHERE oid='public.changes'::pg_catalog.regclass AND relrowsecurity={ce} AND relforcerowsecurity={cf})
 OR NOT EXISTS(SELECT 1 FROM pg_catalog.pg_class WHERE oid='public.column_clocks'::pg_catalog.regclass AND relrowsecurity={ke} AND relforcerowsecurity={kf})
 THEN RAISE EXCEPTION 'fixture did not reach restored flags at outer commit'; END IF;
 IF (SELECT pg_catalog.count(*) FROM public.changes WHERE hub_seq=4242 AND org_id IN ('{org_one}'::uuid,'{org_two}'::uuid))<>2
 THEN RAISE EXCEPTION 'fixture missing composite opaque originals'; END IF;
 FOR opaque IN
  SELECT e.org_id,e.external_id,e.kept_id,e.expected_bytes,c.value,c.value::text AS rendered,c.value_bytes
  FROM (VALUES ('{org_one}'::uuid,'external-one','keep-one',7000),('{org_two}'::uuid,'external-two','keep-two',7001))
   e(org_id,external_id,kept_id,expected_bytes)
  LEFT JOIN public.changes c ON c.org_id=e.org_id AND c.hub_seq=4242
 LOOP
  expected_value:=pg_catalog.jsonb_build_object('projectId',opaque.external_id,'environmentId',opaque.kept_id,'nested','{{"projectId":"inside"}}'::jsonb,'n',123456789012345678901234567890.1234567890123456789::numeric);
  IF opaque.value IS DISTINCT FROM expected_value OR opaque.rendered IS DISTINCT FROM expected_value::text
  OR opaque.value_bytes IS DISTINCT FROM opaque.expected_bytes
  THEN RAISE EXCEPTION 'fixture did not reach exact native opaque restoration'; END IF;
 END LOOP;
 SELECT value::text INTO STRICT canary_value FROM public.changes WHERE org_id='{org_one}'::uuid AND hub_seq=4242;
 PERFORM pg_catalog.nextval('public.control_stage_probe'::pg_catalog.regclass);
 {tail}
END $body$;
REVOKE ALL ON FUNCTION public.control_fault() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.control_fault() TO {owner};
CREATE CONSTRAINT TRIGGER control_stage_trigger AFTER INSERT ON public._sqlx_migrations
 DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN(NEW.version=18 AND NEW.success)
 EXECUTE FUNCTION public.control_fault();
"#,
        owner = ident(&f.owner),
        checksum = checksum18(),
        org_one = f.orgs[0],
        org_two = f.orgs[1],
        ce = ce,
        cf = cf,
        ke = ke,
        kf = kf,
        tail = tail,
    );
    sqlx::raw_sql(&sql).execute(&f.pool).await?;
    let shape: (bool, bool, bool, bool, bool) = sqlx::query_as("SELECT tgconstraint<>0,tgdeferrable,tginitdeferred,tgtype=5,tgenabled='O' FROM pg_catalog.pg_trigger WHERE tgrelid='public._sqlx_migrations'::pg_catalog.regclass AND tgname='control_stage_trigger'")
        .fetch_one(&f.pool).await?;
    require(
        shape == (true, true, true, true, true),
        "exact native ledger INSERT/deferred constraint shape",
    )?;
    let oracle_custody: bool = sqlx::query_scalar(r#"
SELECT p.prosecdef AND p.proconfig=ARRAY['search_path=pg_catalog']::text[]
 AND p.prorettype='pg_catalog.trigger'::pg_catalog.regtype AND b.rolsuper AND b.rolname::text=session_user::text
 AND p.proacl IS NOT NULL AND pg_catalog.has_function_privilege(o.oid,p.oid,'EXECUTE')
 AND NOT EXISTS(SELECT 1 FROM pg_catalog.aclexplode(p.proacl) a WHERE a.privilege_type='EXECUTE' AND (a.grantee NOT IN (p.proowner,o.oid) OR (a.grantee=o.oid AND a.is_grantable)))
FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_roles b ON b.oid=p.proowner
 JOIN pg_catalog.pg_roles o ON o.rolname::text=$1
WHERE p.oid='public.control_fault()'::pg_catalog.regprocedure
"#).bind(&f.owner).fetch_one(&f.pool).await?;
    require(
        oracle_custody,
        "bootstrap-super definer oracle with catalog-only path and restricted execution",
    )
}
async fn probe_once(pool: &PgPool) -> Result {
    let actual: (i64, bool) =
        sqlx::query_as("SELECT last_value,is_called FROM public.control_stage_probe")
            .fetch_one(pool)
            .await?;
    require(
        actual == (1, true),
        "native stage probe must fire exactly once",
    )
}
async fn fault_case(pool: &PgPool, fault: Fault) -> Result {
    let f = Fixture::new(pool, TT, TF).await?;
    install_fault(&f, fault).await?;
    let mut oracle = pool.acquire().await?;
    let before = snapshot(&mut oracle).await?;
    let result = async {
        let error = f
            .run("fault")
            .await?
            .err()
            .ok_or_else(|| Failure::invariant("native fault unexpectedly committed"))?;
        safe_guard(error)?;
        probe_once(pool).await?;
        require(
            snapshot(&mut oracle).await? == before,
            "fault must roll back full prefix17/catalog/ledger/rows/clocks/flags",
        )
    }
    .await;
    drop(oracle);
    result
}

async fn observe_until(pool: &PgPool, sql: &str, a: i32, b: i32, runner: &Runner) -> Result {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let ready: bool = sqlx::query_scalar(sql)
            .bind(a)
            .bind(b)
            .fetch_one(pool)
            .await?;
        if ready {
            return Ok(());
        }
        require(
            !runner.is_finished(),
            "runner ended before required native barrier witness",
        )?;
        require(
            Instant::now() < deadline,
            "native barrier observation deadline",
        )?;
        tokio::task::yield_now().await;
    }
}
async fn runner_pid(pool: &PgPool, name: &str, owner: &str, runner: &Runner) -> Result<i32> {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let pids: Vec<i32> = sqlx::query_scalar("SELECT pid FROM pg_stat_activity WHERE datname=current_database() AND application_name=$1 AND usename=$2")
            .bind(name).bind(owner).fetch_all(pool).await?;
        require(
            pids.len() <= 1,
            "runner application name must identify exactly one native backend",
        )?;
        if let Some(pid) = pids.first() {
            return Ok(*pid);
        }
        require(
            !runner.is_finished(),
            "runner ended before native PID witness",
        )?;
        require(Instant::now() < deadline, "runner PID observation deadline")?;
        tokio::task::yield_now().await;
    }
}
fn spawn_runner(f: &Fixture, name: &str) -> Result<Runner> {
    let operator = tagged(&f.owner_url, name)?;
    let app = f.app_url.clone();
    Ok(tokio::spawn(async move {
        b4hub_db::migrate::run(&operator, &app).await
    }))
}
async fn join_runner(handle: &mut Option<Runner>) -> Result {
    if let Some(handle) = handle.take() {
        handle
            .await
            .map_err(|error| Failure::caused("actual runner task join", error))??;
    }
    Ok(())
}

async fn rr_case(pool: &PgPool) -> Result {
    let f = Fixture::new(pool, TT, TF).await?;
    let database: String = sqlx::query_scalar("SELECT current_database()")
        .fetch_one(pool)
        .await?;
    let setting = format!(
        "ALTER ROLE {} IN DATABASE {} SET default_transaction_isolation='repeatable read'",
        ident(&f.owner),
        ident(&database)
    );
    let mut runner = None;
    let name = f.tag("rr");
    let result = async {
        sqlx::query(&setting).execute(pool).await?;
        let configured: bool = sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM pg_db_role_setting s JOIN pg_roles r ON r.oid=s.setrole JOIN pg_database d ON d.oid=s.setdatabase WHERE r.rolname=$1 AND d.datname=current_database() AND 'default_transaction_isolation=repeatable read'=ANY(s.setconfig))")
            .bind(&f.owner).fetch_one(pool).await?;
        require(configured, "actual role/database repeatable-read default")?;
        let mut check = PgConnection::connect(&f.owner_url).await?;
        let observed = sqlx::query_scalar::<_, String>("SHOW default_transaction_isolation").fetch_one(&mut check).await;
        let closed = check.close().await.map_err(Failure::from);
        let setting_result = observed.map_err(Failure::from).and_then(|value| require(value == "repeatable read", "fresh role connection uses RR"));
        merge(setting_result, closed)?;

        let mut writer = pool.acquire().await?;
        let writer_pid: i32 = sqlx::query_scalar("SELECT pg_backend_pid()").fetch_one(&mut *writer).await?;
        let before_ledger = original_ledger(&mut writer).await?;
        let mut transaction = Some(writer.begin().await?);
        let mut committed = false;
        let body = async {
            let tx = transaction.as_mut().ok_or_else(|| Failure::invariant("owned writer transaction"))?;
            sqlx::query("INSERT INTO projects(id,name,org_id,user_id,device_id,owner_device_id) VALUES('p_rr','writer',$1,$2,$3,$3)")
                .bind(f.orgs[0]).bind(f.users[0]).bind(f.devices[0]).execute(&mut **tx).await?;
            sqlx::query("INSERT INTO threads(id,\"projectId\",org_id,user_id,device_id,owner_device_id) VALUES('t_rr','p_rr',$1,$2,$3,$3)")
                .bind(f.orgs[0]).bind(f.users[0]).bind(f.devices[0]).execute(&mut **tx).await?;
            sqlx::query(r#"INSERT INTO changes(org_id,hub_seq,device_id,device_seq,user_id,wall,"table",row_id,op,"column",value,hlc,value_bytes)
SELECT $1,seq,$3,seq,$2,seq,tbl,row_id,op,NULL,val,'rr-'||seq::text,octet_length(val::text) FROM(VALUES
 (8001::bigint,'projects','p_rr','insert','{"id":"p_rr","name":"writer"}'::jsonb),
 (8002,'threads','t_rr','insert','{"id":"t_rr","projectId":"p_rr"}'::jsonb),
 (8003,'displayItems','opaque-rr-new','update','{"projectId":"new-external","environmentId":"new-keep"}'::jsonb))s(seq,tbl,row_id,op,val)"#)
                .bind(f.orgs[0]).bind(f.users[0]).bind(f.devices[0]).execute(&mut **tx).await?;
            sqlx::query("INSERT INTO column_clocks(org_id,\"table\",row_id,\"column\",hlc) VALUES($1,'projects','p_rr','name','rr'),($1,'threads','t_rr','projectId','rr')")
                .bind(f.orgs[0]).execute(&mut **tx).await?;
            let updated = sqlx::query("UPDATE changes SET value='{\"projectId\":\"committed-external\",\"environmentId\":\"committed-keep\",\"n\":987654321098765432109876543210.987654321}'::jsonb,value_bytes=8765 WHERE org_id=$1 AND hub_seq=4242")
                .bind(f.orgs[0]).execute(&mut **tx).await?;
            require(updated.rows_affected() == 1, "writer must update an existing opaque row")?;
            sqlx::raw_sql("CREATE TEMP TABLE rr_opaque_expected AS SELECT c.*,c.value::text rendered FROM public.changes c WHERE row_id LIKE 'opaque-%';")
                .execute(&mut **tx).await?;
            runner = Some(spawn_runner(&f, &name)?);
            let handle = runner.as_ref().ok_or_else(|| Failure::invariant("owned RR runner handle"))?;
            let pid = runner_pid(pool, &name, &f.owner, handle).await?;
            observe_until(pool, "SELECT EXISTS(SELECT 1 FROM pg_locks WHERE pid=$1 AND relation='public.projects'::regclass AND mode='AccessExclusiveLock' AND NOT granted) AND $2=ANY(pg_blocking_pids($1)) AND (SELECT count(*) FROM pg_locks WHERE pid=$2 AND granted AND mode='RowExclusiveLock' AND relation IN('public.projects'::regclass,'public.changes'::regclass))=2", pid, writer_pid, handle).await?;
            transaction.take().ok_or_else(|| Failure::invariant("writer commit handle"))?.commit().await?;
            committed = true;
            Ok(())
        }.await;
        let rolled = if let Some(tx) = transaction.take() { tx.rollback().await.map_err(Failure::from) } else { Ok(()) };
        drop(transaction);
        // Always release writer before joining B, even when observation or setup failed.
        if !committed {
            // Closing consumes the native connection even if rollback/COMMIT acknowledgement failed.
            let closed = writer.close().await.map_err(Failure::from);
            let joined = join_runner(&mut runner).await;
            return merge(merge(merge(body, rolled), closed), joined);
        }
        let joined = join_runner(&mut runner).await;
        let combined = merge(merge(body, rolled), joined);
        let checked = async {
            combined?;
            require(committed, "writer committed only after exact native wait")?;
            let rows: bool = sqlx::query_scalar(r#"SELECT
 EXISTS(SELECT 1 FROM environments WHERE org_id=$1 AND id='p_rr' AND name='writer')
 AND EXISTS(SELECT 1 FROM threads WHERE org_id=$1 AND id='t_rr' AND "environmentId"='p_rr')
 AND EXISTS(SELECT 1 FROM changes WHERE org_id=$1 AND hub_seq=8001 AND "table"='environments' AND row_id='p_rr' AND op='insert' AND "column" IS NULL AND value='{"id":"p_rr","name":"writer"}'::jsonb AND value_bytes=octet_length(value::text))
 AND EXISTS(SELECT 1 FROM changes WHERE org_id=$1 AND hub_seq=8002 AND "table"='threads' AND row_id='t_rr' AND op='insert' AND "column" IS NULL AND value='{"id":"t_rr","environmentId":"p_rr"}'::jsonb AND value_bytes=octet_length(value::text))
 AND EXISTS(SELECT 1 FROM column_clocks WHERE org_id=$1 AND "table"='environments' AND row_id='p_rr' AND "column"='name' AND hlc='rr')
 AND EXISTS(SELECT 1 FROM column_clocks WHERE org_id=$1 AND "table"='threads' AND row_id='t_rr' AND "column"='environmentId' AND hlc='rr')
 AND NOT EXISTS(SELECT 1 FROM rr_opaque_expected b LEFT JOIN public.changes a USING(org_id,hub_seq) WHERE a.org_id IS NULL OR to_jsonb(a) IS DISTINCT FROM(to_jsonb(b)-'rendered') OR a.value::text IS DISTINCT FROM b.rendered)
 AND NOT EXISTS(SELECT 1 FROM changes WHERE "table" IN('projects','projectFolders') OR "column"='projectId')
 AND NOT EXISTS(SELECT 1 FROM column_clocks WHERE "table" IN('projects','projectFolders') OR "column"='projectId')
 AND (SELECT count(*) FROM changes)=23
 AND (SELECT count(*) FROM column_clocks)=6
 AND (SELECT count(*) FROM rr_opaque_expected)=11"#)
                .bind(f.orgs[0]).fetch_one(&mut *writer).await?;
            require(rows, "RR sees committed feed/clocks/new and updated opaque preimages")?;
            complete_ledger(&mut writer).await?;
            require(original_ledger(&mut writer).await? == before_ledger, "RR preserves full original ledger rows")?;
            f.check_flags().await?;
            f.no_tagged_backends(std::slice::from_ref(&name)).await
        }.await;
        drop(writer);
        checked
    }.await;
    // Releasing a failed writer/runner occurs before resetting this fixture-only setting.
    let joined = join_runner(&mut runner).await;
    let reset = sqlx::query(&format!(
        "ALTER ROLE {} IN DATABASE {} RESET default_transaction_isolation",
        ident(&f.owner),
        ident(&database)
    ))
    .execute(pool)
    .await
    .map(|_| ())
    .map_err(Failure::from);
    let reset_checked = if reset.is_ok() {
        sqlx::query_scalar::<_, bool>("SELECT NOT EXISTS(SELECT 1 FROM pg_db_role_setting s JOIN pg_roles r ON r.oid=s.setrole JOIN pg_database d ON d.oid=s.setdatabase WHERE r.rolname=$1 AND d.datname=current_database() AND 'default_transaction_isolation=repeatable read'=ANY(s.setconfig))")
            .bind(&f.owner).fetch_one(pool).await.map_err(Failure::from)
            .and_then(|absent| require(absent, "fixture role/database RR setting reset"))
    } else {
        Ok(())
    };
    merge(merge(merge(result, joined), reset), reset_checked)
}

async fn concurrent_case(pool: &PgPool) -> Result {
    let f = Fixture::new(pool, TT, TF).await?;
    let gate = (1_144_001, 1_145_001);
    install_fault(&f, Fault::Gate(gate.0, gate.1)).await?;
    let mut oracle = pool.acquire().await?;
    remember_opaque(&mut oracle).await?;
    let before_ledger = original_ledger(&mut oracle).await?;
    let mut controller = pool.acquire().await?;
    let controller_pid: i32 = sqlx::query_scalar("SELECT pg_backend_pid()")
        .fetch_one(&mut *controller)
        .await?;
    sqlx::query("SELECT pg_advisory_lock($1,$2)")
        .bind(gate.0)
        .bind(gate.1)
        .execute(&mut *controller)
        .await?;
    let mut gate_held = true;
    let mut a = None;
    let mut b = None;
    let names = [f.tag("commit_a"), f.tag("commit_b")];
    let result = async {
        a = Some(spawn_runner(&f, &names[0])?);
        let ah = a.as_ref().ok_or_else(|| Failure::invariant("owned commit A handle"))?;
        let apid = runner_pid(pool, &names[0], &f.owner, ah).await?;
        observe_until(pool, "SELECT EXISTS(SELECT 1 FROM pg_locks x JOIN pg_locks y ON x.locktype=y.locktype AND x.database IS NOT DISTINCT FROM y.database AND x.classid=y.classid AND x.objid=y.objid AND x.objsubid=y.objsubid WHERE x.pid=$1 AND x.locktype='advisory' AND x.objsubid=2 AND NOT x.granted AND y.pid=$2 AND y.granted) AND $2=ANY(pg_blocking_pids($1)) AND EXISTS(SELECT 1 FROM pg_stat_activity WHERE pid=$1 AND upper(btrim(query))='COMMIT') AND (SELECT last_value=1 AND is_called FROM public.control_stage_probe)", apid, controller_pid, ah).await?;
        b = Some(spawn_runner(&f, &names[1])?);
        let bh = b.as_ref().ok_or_else(|| Failure::invariant("owned commit B handle"))?;
        let bpid = runner_pid(pool, &names[1], &f.owner, bh).await?;
        observe_until(pool, "SELECT EXISTS(SELECT 1 FROM pg_locks x JOIN pg_locks y ON x.locktype=y.locktype AND x.database IS NOT DISTINCT FROM y.database AND x.classid=y.classid AND x.objid=y.objid AND x.objsubid=y.objsubid WHERE x.pid=$1 AND x.locktype='advisory' AND x.objsubid=1 AND x.granted AND y.pid=$2 AND NOT y.granted) AND $1=ANY(pg_blocking_pids($2))", apid, bpid, bh).await?;
        let still17: bool = sqlx::query_scalar("SELECT count(*)=17 AND max(version)=17 FROM _sqlx_migrations").fetch_one(pool).await?;
        require(still17, "uncommitted eighteen cannot be visible while COMMIT is gated")?;
        Ok(())
    }.await;
    let unlocked = if gate_held {
        let released: std::result::Result<bool, sqlx::Error> =
            sqlx::query_scalar("SELECT pg_advisory_unlock($1,$2)")
                .bind(gate.0)
                .bind(gate.1)
                .fetch_one(&mut *controller)
                .await;
        if matches!(&released, Ok(true)) {
            gate_held = false;
        }
        released
            .map_err(Failure::from)
            .and_then(|released| require(released, "controller releases only its owned exact gate"))
    } else {
        Ok(())
    };
    // Never propagate an assertion before releasing the gate and joining BOTH actual calls.
    let controller_closed = controller.close().await.map_err(Failure::from);
    let a_joined = join_runner(&mut a).await;
    let b_joined = join_runner(&mut b).await;
    let combined = merge(
        merge(merge(merge(result, unlocked), controller_closed), a_joined),
        b_joined,
    );
    let checked = async {
        combined?;
        require(!gate_held, "controller gate bookkeeping")?;
        f.no_tagged_backends(&names).await?;
        probe_once(pool).await?;
        f.check_flags().await?;
        positive(&f, &mut oracle).await?;
        let original = original_ledger(&mut oracle).await?;
        require(
            original == before_ledger,
            "concurrent migration preserves prefix ledger facts",
        )?;
        let before = snapshot(&mut oracle).await?;
        f.run("commit_again").await??;
        require(
            snapshot(&mut oracle).await? == before,
            "concurrent result remains historically idempotent",
        )?;
        probe_once(pool).await?;
        Ok(())
    }
    .await;
    checked
}

async fn finished(pool: PgPool, outcome: Result) {
    pool.close().await;
    assert!(outcome.is_ok(), "{outcome:?}");
}

#[sqlx::test(migrations = false)]
async fn pending_18_non_super_owner_preserves_two_orgs_forced(pool: PgPool) {
    let result = owner_case(&pool, TT, TF, true).await;
    finished(pool, result).await;
}
#[sqlx::test(migrations = false)]
async fn pending_18_preserves_enabled_nonforced_flags(pool: PgPool) {
    let result = owner_case(&pool, TF, FF, false).await;
    finished(pool, result).await;
}
#[sqlx::test(migrations = false)]
async fn pending_18_preserves_disabled_nonforced_flags(pool: PgPool) {
    let result = owner_case(&pool, FF, FT, false).await;
    finished(pool, result).await;
}
#[sqlx::test(migrations = false)]
async fn pending_18_preserves_disabled_forced_flags(pool: PgPool) {
    let result = owner_case(&pool, FT, TT, false).await;
    finished(pool, result).await;
}
#[sqlx::test(migrations = false)]
async fn pending_18_rejects_app_role_without_mutation(pool: PgPool) {
    let result = async {
        let f = Fixture::new(&pool, TT, TF).await?;
        sqlx::raw_sql("GRANT USAGE ON SCHEMA public TO b4hub_app; GRANT SELECT,INSERT,UPDATE,DELETE ON ALL TABLES IN SCHEMA public TO b4hub_app; GRANT USAGE,SELECT ON ALL SEQUENCES IN SCHEMA public TO b4hub_app;")
            .execute(&pool).await?;
        let mut oracle = pool.acquire().await?;
        let before = snapshot(&mut oracle).await?;
        let name = f.tag("app_refusal");
        let outcome = b4hub_db::migrate::run(&tagged(&f.app_url, &name)?, &f.app_url).await;
        f.no_tagged_backends(&[name]).await?;
        require(outcome.is_err(), "app operator must refuse; no extra CREATE/owner privilege")?;
        require(snapshot(&mut oracle).await? == before, "app refusal leaves full prefix17 unchanged")
    }.await;
    finished(pool, result).await;
}
#[sqlx::test(migrations = false)]
async fn pending_18_rejects_ambiguous_structural_insert(pool: PgPool) {
    let result = async {
        let f = Fixture::new(&pool, TT, TF).await?;
        sqlx::query("INSERT INTO changes(org_id,hub_seq,device_id,device_seq,user_id,wall,\"table\",row_id,op,value,hlc,value_bytes) VALUES($1,5000,$3,5000,$2,5000,'threads','t1','insert','{\"id\":\"t1\",\"projectId\":\"p1\",\"environmentId\":\"conflicting\"}'::jsonb,'ambiguous',91)")
            .bind(f.orgs[0]).bind(f.users[0]).bind(f.devices[0]).execute(&pool).await?;
        let mut oracle = pool.acquire().await?;
        let before = snapshot(&mut oracle).await?;
        let error = f.run("ambiguous").await?.err().ok_or_else(|| Failure::invariant("ambiguous structural image unexpectedly migrated"))?;
        safe_guard(error)?;
        require(snapshot(&mut oracle).await? == before, "ambiguous preflight leaves full prefix17 unchanged")
    }.await;
    finished(pool, result).await;
}
#[sqlx::test(migrations = false)]
async fn restore_constraint_error_rolls_back_pending_18_safely(pool: PgPool) {
    let result = fault_case(&pool, Fault::Restore).await;
    finished(pool, result).await;
}
#[sqlx::test(migrations = false)]
async fn deferred_commit_error_rolls_back_pending_18_safely(pool: PgPool) {
    let result = fault_case(&pool, Fault::Commit).await;
    finished(pool, result).await;
}
#[sqlx::test(migrations = false)]
async fn repeatable_read_waits_for_writer_before_capture(pool: PgPool) {
    let result = rr_case(&pool).await;
    finished(pool, result).await;
}
#[sqlx::test(migrations = false)]
async fn concurrent_public_runners_hold_lock_through_commit(pool: PgPool) {
    let result = concurrent_case(&pool).await;
    finished(pool, result).await;
}

// A deferred event on changes itself blocks the guard's subsequent RLS ALTER.
// Preserve that fail-closed limitation separately from the outer-COMMIT seam.
#[sqlx::test(migrations = false)]
async fn deferred_changes_trigger_collision_refuses_without_mutation(pool: PgPool) {
    let result =
        async {
            let f = Fixture::new(&pool, TT, TF).await?;
            install_fault(&f, Fault::ChangesCollision).await?;
            let mut oracle = pool.acquire().await?;
            let before = snapshot(&mut oracle).await?;
            let error = f.run("changes_collision").await?.err().ok_or_else(|| {
                Failure::invariant("deferred changes collision unexpectedly migrated")
            })?;
            safe_guard(error)?;
            let probe: (i64, bool) =
                sqlx::query_as("SELECT last_value,is_called FROM public.control_stage_probe")
                    .fetch_one(&pool)
                    .await?;
            require(
                probe == (1, false),
                "deferred changes function must not run before DDL refusal",
            )?;
            require(snapshot(&mut oracle).await? == before,
            "deferred changes collision rolls back full prefix17/catalog/ledger/rows/clocks/flags")
        }
        .await;
    finished(pool, result).await;
}
