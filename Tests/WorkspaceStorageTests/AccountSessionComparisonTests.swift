import Foundation
import Synchronization
import Testing
import WorkspacePlatform
import WorkspaceProtocol

@testable import WorkspaceStorage

// These are native comparison controls, not HTTP, authentication, admission or quiescence proof.
@Suite(.serialized, .timeLimit(.minutes(1))) struct AccountSessionComparisonTests {
  @Test func p2bB01EmptyLegitimateTableCapturesSealedAbsence() throws {
    try P2BNativeFixture.withFixture { f in
      try f.requireCatalog()
      let empty = try f.scalar("SELECT count(*) AS n FROM public.\"hubLink\"") == 0
      #expect(empty)
      let before = try f.image()
      let calls = Mutex(0)
      let check = AccountSessionComparisonCheck { calls.withLock { $0 += 1 } }
      let captureProbe = try f.probe()
      let original = try f.capture(check: check)
      let absent = !p2bIsLinked(original.presence)
      let captureCalls = calls.withLock { $0 } == 10
      #expect(absent && captureCalls)
      p2bSuccessfulSample(captureProbe.snapshot())
      try f.clear(captureProbe)
      let comparisonProbe = try f.probe()
      try f.database.compareOriginalAccountSession(expectedSnapshot: original, memoryCheck: check)
      let compareCalls = calls.withLock { $0 } == 20
      let unchanged = try f.image() == before
      #expect(compareCalls && unchanged)
      p2bSuccessfulSample(comparisonProbe.snapshot())
      p2bPrivacy(original, name: "AccountSessionComparisonSnapshot")
      p2bPrivacy(check, name: "AccountSessionComparisonCheck")
      // Compile controls separately qualify the inaccessible initializer; no forged absence input.
    }
  }

  @Test func p2bB02LinkedCapturesOriginalByteExactFacts() throws {
    try P2BNativeFixture.withFixture(linked: true) { f in
      let original = try f.capture()
      let linked = p2bIsLinked(original.presence)
      #expect(linked)
      try f.compare(original)
      for base in ["HTTPS://P2B.INVALID/Deployment/", "https://p2b.invalid/Deployment"] {
        _ = try f.capture(base: base)
      }
      for base in [
        "https://p2b.invalid/deployment", "https://p2b.invalid:443/Deployment",
        "https://p2b.invalid/%44eployment",
      ] {
        p2bRefusal { _ = try f.capture(base: base) }
      }
      try f.sql(
        "UPDATE public.\"hubLink\" SET \"deviceId\"=$1, \"tokenRef\"=$2 WHERE id=1",
        ["d\u{00e9}", "secret:r\u{00e9}"])
      _ = try f.capture(device: "d\u{00e9}", reference: "secret:r\u{00e9}")
      p2bRefusal { _ = try f.capture(device: "de\u{0301}", reference: "secret:r\u{00e9}") }
      p2bRefusal { _ = try f.capture(device: "d\u{00e9}", reference: "secret:re\u{0301}") }
      let unequal =
        ProtocolCredentialReference("secret:r\u{00e9}")
        != ProtocolCredentialReference("secret:re\u{0301}")
      #expect(unequal)
    }
  }

  @Test func p2bB03MalformedReferenceNeverMeansAbsent() throws {
    for reference in ["", "wrong:fixture", "secret:"] {
      try P2BNativeFixture.withFixture(linked: true) { f in
        try f.sql("UPDATE public.\"hubLink\" SET \"tokenRef\"=$1", [reference])
        p2bRefusal { _ = try f.capture() }
      }
      try P2BNativeFixture.withFixture { f in
        let probe = try f.probe()
        p2bRefusal { _ = try f.capture(reference: reference) }
        let beforeWait = probe.snapshot().waitStart == nil
        #expect(beforeWait)
      }
    }
    try P2BNativeFixture.withFixture(linked: true) { f in
      p2bRefusal { _ = try f.capture(reference: nil) }
      _ = try f.capture()
      try f.sql("ALTER TABLE public.\"hubLink\" ALTER COLUMN \"tokenRef\" DROP NOT NULL")
      try f.sql("UPDATE public.\"hubLink\" SET \"tokenRef\"=NULL")
      let nullable =
        try f.scalar(
          "SELECT count(*) AS n FROM pg_attribute WHERE attrelid='public.\"hubLink\"'::regclass AND attname='tokenRef' AND NOT attnotnull"
        ) == 1
      #expect(nullable)
      p2bRefusal { _ = try f.capture() }
    }
    var fields = p2bRawFields(linked: true)
    fields[6] = p2bField("native_reference", 25, [115, 101, 99, 114, 101, 116, 58, 0])
    p2bDecoderRefusal(AccountSessionRawResult(rowCount: 1, fieldCount: 7, fields: fields))
  }

  @Test func p2bB04MissingRelationOrRequiredColumnFails() throws {
    let corruptions = [
      "DROP TABLE public.\"hubLink\"",
      "ALTER TABLE public.\"hubLink\" RENAME TO \"renamedHubLink\"",
      "ALTER TABLE public.\"hubLink\" DROP COLUMN id CASCADE",
      "ALTER TABLE public.\"hubLink\" DROP COLUMN url CASCADE",
      "ALTER TABLE public.\"hubLink\" DROP COLUMN \"deviceId\" CASCADE",
      "ALTER TABLE public.\"hubLink\" DROP COLUMN \"joinedAt\" CASCADE",
      "ALTER TABLE public.\"hubLink\" DROP COLUMN \"tokenRef\" CASCADE",
      "ALTER TABLE public.\"hubLink\" ALTER COLUMN id TYPE bigint",
      "ALTER TABLE public.\"hubLink\" ALTER COLUMN url TYPE varchar",
      "CREATE DOMAIN public.p2b_text AS text; ALTER TABLE public.\"hubLink\" ALTER COLUMN url TYPE public.p2b_text",
      "ALTER TABLE public.\"hubLink\" ALTER COLUMN \"deviceId\" DROP NOT NULL",
    ]
    for (index, sql) in corruptions.enumerated() {
      try P2BNativeFixture.withFixture(linked: index.isMultiple(of: 2)) { f in
        try f.sql(sql)
        let arranged: Bool
        switch index {
        case 0, 1:
          arranged =
            try f.scalar(
              "SELECT count(*) AS n FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relname='hubLink'"
            ) == 0
        case 2...6:
          let column = ["id", "url", "deviceId", "joinedAt", "tokenRef"][index - 2]
          arranged =
            try f.scalar(
              "SELECT count(*) AS n FROM pg_attribute WHERE attrelid='public.\"hubLink\"'::regclass AND attname=$1 AND NOT attisdropped",
              [column]) == 0
        case 7:
          arranged =
            try f.scalar(
              "SELECT count(*) AS n FROM pg_attribute WHERE attrelid='public.\"hubLink\"'::regclass AND attname='id' AND atttypid=20"
            ) == 1
        case 8:
          arranged =
            try f.scalar(
              "SELECT count(*) AS n FROM pg_attribute WHERE attrelid='public.\"hubLink\"'::regclass AND attname='url' AND atttypid=1043"
            ) == 1
        case 9:
          arranged =
            try f.scalar(
              "SELECT count(*) AS n FROM pg_attribute a JOIN pg_type t ON t.oid=a.atttypid WHERE a.attrelid='public.\"hubLink\"'::regclass AND a.attname='url' AND t.typtype='d' AND t.typbasetype=25"
            ) == 1
        default:
          arranged =
            try f.scalar(
              "SELECT count(*) AS n FROM pg_attribute WHERE attrelid='public.\"hubLink\"'::regclass AND attname='deviceId' AND NOT attnotnull"
            ) == 1
        }
        #expect(arranged)
        p2bRefusal { _ = try f.capture() }
      }
    }
    try P2BNativeFixture.withFixture(linked: true) { f in
      try f.sql(
        "ALTER TABLE public.\"hubLink\" ADD COLUMN p2b_extra text; ALTER TABLE public.\"hubLink\" DROP CONSTRAINT \"hubLink_pkey\"; ALTER TABLE public.\"hubLink\" ADD PRIMARY KEY (id) INCLUDE (url)"
      )
      let included =
        try f.scalar(
          "SELECT count(*) AS n FROM pg_index WHERE indrelid='public.\"hubLink\"'::regclass AND indisprimary AND indnkeyatts=1 AND indnatts=2"
        ) == 1
      let nullableOwnedAs =
        try f.scalar(
          "SELECT count(*) AS n FROM pg_attribute WHERE attrelid='public.\"hubLink\"'::regclass AND attname IN ('ownedAs','p2b_extra') AND NOT attnotnull"
        ) == 2
      #expect(included && nullableOwnedAs)
      let original = try f.capture()
      try f.compare(original)
    }
  }

  @Test func p2bB05ViewsAndRLSHiddenEmptyRefuse() throws {
    try P2BNativeFixture.withFixture { f in
      try f.sql(
        "ALTER TABLE public.\"hubLink\" RENAME TO p2b_backing; CREATE VIEW public.\"hubLink\" AS SELECT * FROM public.p2b_backing"
      )
      let view =
        try f.scalar(
          "SELECT count(*) AS n FROM pg_class WHERE oid='public.\"hubLink\"'::regclass AND relkind='v'") == 1
      #expect(view)
      p2bRefusal { _ = try f.capture() }
      let pool = try f.pool()
      p2bAnyRefusal {
        _ = try pool.readAccountSessionNativeFacts(memoryCheck: AccountSessionComparisonCheck {})
      }
    }
    try P2BNativeFixture.withFixture(linked: true) { f in
      try f.withRole { role, pool in
        let plain = try pool.readAccountSessionNativeFacts(memoryCheck: AccountSessionComparisonCheck {})
        let linked = p2bFactsLinked(plain)
        #expect(linked)
        try f.sql(
          "ALTER TABLE public.\"hubLink\" ENABLE ROW LEVEL SECURITY; CREATE POLICY p2b_hide ON public.\"hubLink\" USING (false)"
        )
        let ownerSees = try f.scalar("SELECT count(*) AS n FROM public.\"hubLink\"") == 1
        let hidden = try pool.withConnection {
          try $0.execute("SELECT count(*) AS n FROM public.\"hubLink\"").rows.first?.int("n") == 0
        }
        let roleReal =
          try f.scalar(
            "SELECT count(*) AS n FROM pg_roles WHERE rolname=$1 AND NOT rolsuper AND NOT rolbypassrls",
            [role]) == 1
        #expect(ownerSees && hidden && roleReal)
        p2bAnyRefusal {
          _ = try pool.readAccountSessionNativeFacts(memoryCheck: AccountSessionComparisonCheck {})
        }
        p2bRefusal { _ = try f.capture() }
      }
    }
    try P2BNativeFixture.withFixture { f in
      try f.sql(
        "ALTER TABLE public.\"hubLink\" ENABLE ROW LEVEL SECURITY; ALTER TABLE public.\"hubLink\" FORCE ROW LEVEL SECURITY"
      )
      let force =
        try f.scalar(
          "SELECT count(*) AS n FROM pg_class WHERE oid='public.\"hubLink\"'::regclass AND relrowsecurity AND relforcerowsecurity"
        ) == 1
      #expect(force)
      p2bRefusal { _ = try f.capture() }
    }
  }

  @Test func p2bB06AllRowsAndCheckOnlyDriftAreExplicit() throws {
    try P2BNativeFixture.withFixture { f in
      try f.sql("ALTER TABLE public.\"hubLink\" DROP CONSTRAINT \"hubLink_id_check\"")
      let noCheck =
        try f.scalar(
          "SELECT count(*) AS n FROM pg_constraint WHERE conrelid='public.\"hubLink\"'::regclass AND contype='c'"
        ) == 0
      #expect(noCheck)
      _ = try f.capture()
      try f.link()
      _ = try f.capture()
      try f.sql("UPDATE public.\"hubLink\" SET id=2")
      let soleTwo = try f.scalar("SELECT count(*) AS n FROM public.\"hubLink\" WHERE id=2") == 1
      #expect(soleTwo)
      p2bRefusal { _ = try f.capture() }
      try f.link()
      let two = try f.scalar("SELECT count(*) AS n FROM public.\"hubLink\"") == 2
      #expect(two)
      p2bRefusal { _ = try f.capture() }
    }
    for (index, mutation) in [
      "ALTER TABLE public.\"hubLink\" DROP CONSTRAINT \"hubLink_pkey\"",
      "ALTER TABLE public.\"hubLink\" DROP CONSTRAINT \"hubLink_pkey\"; ALTER TABLE public.\"hubLink\" ADD PRIMARY KEY(id,url)",
      "ALTER TABLE public.\"hubLink\" DROP CONSTRAINT \"hubLink_pkey\"; ALTER TABLE public.\"hubLink\" ALTER COLUMN id DROP NOT NULL",
      "ALTER TABLE public.\"hubLink\" DROP CONSTRAINT \"hubLink_pkey\"; INSERT INTO public.\"hubLink\" SELECT * FROM public.\"hubLink\"",
    ].enumerated() {
      try P2BNativeFixture.withFixture(linked: true) { f in
        try f.sql(mutation)
        let primaryCount = try f.scalar(
          "SELECT count(*) AS n FROM pg_constraint WHERE conrelid='public.\"hubLink\"'::regclass AND contype='p'"
        )
        let compositeCount = try f.scalar(
          "SELECT count(*) AS n FROM pg_constraint WHERE conrelid='public.\"hubLink\"'::regclass AND contype='p' AND array_length(conkey,1)=2"
        )
        let nullableCount = try f.scalar(
          "SELECT count(*) AS n FROM pg_attribute WHERE attrelid='public.\"hubLink\"'::regclass AND attname='id' AND NOT attnotnull"
        )
        let primaryShape = primaryCount == (index == 1 ? 1 : 0) && (index != 1 || compositeCount == 1)
        let nullability = index != 2 || nullableCount == 1
        let actualRows = try f.scalar("SELECT count(*) AS n FROM public.\"hubLink\"") == (index == 3 ? 2 : 1)
        #expect(primaryShape && nullability && actualRows)
        p2bRefusal { _ = try f.capture() }
      }
    }
  }

  @Test func p2bB07StrictNativeLengthsShapeAndSQLASCII() throws {
    try P2BNativeFixture.withFixture { f in
      try f.nativeResults()
      try f.pureResults()
    }
    try P2BNativeFixture.withFixture(linked: true, ascii: true) { f in
      _ = try f.capture()
      try f.sql(
        "UPDATE public.\"hubLink\" SET url=pg_catalog.convert_from(pg_catalog.decode('68747470733a2f2f7032622e696e76616c69642fff','hex'),'SQL_ASCII') WHERE id=1"
      )
      let actualFF = try f.nativeBytes("SELECT url FROM public.\"hubLink\"", column: 0).last == 255
      #expect(actualFF)
      guard actualFF else { throw P2BFixtureFailure.incomplete }
      p2bRefusal { _ = try f.capture() }
    }
  }

  @Test func p2bB08OriginalFactsAndDatabaseCannotRetarget() throws {
    try P2BNativeFixture.withFixture(linked: true) { f in
      let original = try f.capture()
      for (column, value) in [
        ("url", "https://other.invalid/Deployment"), ("deviceId", "other"),
        ("joinedAt", "later"), ("tokenRef", "secret:other"),
      ] {
        try f.sql("UPDATE public.\"hubLink\" SET \(Rows.quote(column))=$1", [value])
        p2bRefusal { try f.compare(original) }
        try f.link()
      }
      try f.sql(
        "UPDATE public.\"hubLink\" SET \"deviceName\"='another', \"orgSlug\"='another', username='another', cursor=9, \"lastError\"='another'"
      )
      try f.compare(original)
      let other = try WorkspaceDatabase(endpoint: f.endpoint, binDir: f.binDir)
      defer { _ = other.closeForMigration(timeout: .seconds(2)) }
      let otherProbe = AccountSessionComparisonTestProbe()
      let installed = other.installAccountSessionComparisonTestProbe(otherProbe)
      #expect(installed)
      defer { _ = other.clearAccountSessionComparisonTestProbe(otherProbe) }
      p2bRefusal {
        try other.compareOriginalAccountSession(
          expectedSnapshot: original, memoryCheck: AccountSessionComparisonCheck {})
      }
      let noRetarget = otherProbe.snapshot().waitStart == nil
      #expect(noRetarget)
      let probe = try f.probe()
      p2bRefusal {
        _ = try f.database.captureAccountSessionComparison(
          accountID: "account", databaseName: "wrong", hubBase: P2BNativeFixture.base,
          deviceID: P2BNativeFixture.device, tokenReference: P2BNativeFixture.reference,
          memoryCheck: AccountSessionComparisonCheck {})
      }
      let noWait = probe.snapshot().waitStart == nil
      #expect(noWait)
    }
  }

  @Test func p2bB09PresenceBranchChangesRefuseOriginal() throws {
    try P2BNativeFixture.withFixture { f in
      let absent = try f.capture(reference: nil)
      try f.link()
      p2bRefusal { try f.compare(absent) }
      let linked = try f.capture()
      try f.sql("DELETE FROM public.\"hubLink\"")
      p2bRefusal { try f.compare(linked) }
      _ = try f.capture(reference: nil)
      p2bRefusal { try f.compare(linked) }
    }
  }

  @Test func p2bB10ProtocolStateIsNotAComparisonDependency() throws {
    for linked in [false, true] {
      try P2BNativeFixture.withFixture(linked: linked) { f in
        _ = try f.database.insertConnection(
          Connection(
            id: "p2b-modern", kind: .agentProtocol, label: "fixture", target: "https://p2b.invalid/agent",
            nativeScope: "native", peerProfile: .agentProtocol, agentId: "agent",
            authMode: ConnectionAuthMode.none))
        let requiresTwo = try f.database.protocolSyncRequirement() == .protocolTwo
        #expect(requiresTwo)
        try f.sql(
          "INSERT INTO public.settings(key,value) VALUES('__b4app_agent_protocol_activation_v1','\"malformed\"'::jsonb) ON CONFLICT(key) DO UPDATE SET value=EXCLUDED.value"
        )
        let before = try f.image()
        let original = try f.capture()
        try f.compare(original)
        let unchanged = try f.image() == before
        #expect(unchanged)
        if linked {
          p2bAnyRefusal {
            _ = try f.database.captureProtocolVerification(
              accountID: "account",
              expectedMembership: ProtocolNativeMembership(
                canonicalHubBase: P2BNativeFixture.base, deviceID: P2BNativeFixture.device,
                linkJoinedAt: P2BNativeFixture.joined))
          }
        }
        try f.sql("ALTER TABLE public.settings RENAME TO p2b_settings_saved")
        let noSettingsBefore = try f.image()
        let absentDependency = try f.capture()
        try f.compare(absentDependency)
        let noRepair = try f.image() == noSettingsBefore
        #expect(noRepair)
        try f.sql("ALTER TABLE public.p2b_settings_saved RENAME TO settings")
      }
    }
  }

  @Test func p2bB11QueuedCheckoutUsesOneFiveSecondDeadline() throws {
    try P2BNativeFixture.withFixture { f in
      let pool = try f.pool()
      let hold = f.resources.hold(seconds: 10)
      let holder = f.resources.worker {
        try pool.withConnection { c in
          try p2bOne(c); return hold.wait()
        }
      }
      try p2bRequire(p2bPoll { hold.entered })
      let probe = try f.poolProbe(pool)
      let reader = f.resources.worker {
        p2bAnyRejected {
          _ = try pool.readAccountSessionNativeFacts(memoryCheck: AccountSessionComparisonCheck {})
        }
      }
      try p2bRequire(reader.join())
      let sample = probe.snapshot()
      let deadline = sample.waitDeadline ?? 0
      let start = sample.waitStart ?? 0
      let exact = deadline > start && deadline - start == 5_000_000_000
      let held = hold.held && !hold.expired && hold.expiry.uptimeNanoseconds >= deadline + 2_000_000_000
      let noNative =
        !sample.leaseEntered
        && !sample.slotSignalled && sample.acceptedGuards == 0 && sample.refusedGuards == 0
        && sample.phaseCounts[AccountSessionComparisonPhase.afterConnectBeforeG3.rawValue] == 0
        && sample.commandStarts.allSatisfy { $0 == 0 }
      #expect(exact && held && noNative)
      let recoveryMarked = Mutex(false)
      let recoveryEntered = Mutex(false)
      let recovery = f.resources.worker {
        try pool.withConnection(beforeWaiting: { recoveryMarked.withLock { $0 = true } }) { c in
          recoveryEntered.withLock { $0 = true }; try p2bOne(c); return !hold.held
        }
      }
      try p2bRequire(p2bPoll { recoveryMarked.withLock { $0 } })
      let stillBlocked = !recoveryEntered.withLock { $0 } && hold.held
      #expect(stillBlocked)
      hold.release()
      let joined = holder.join() && recovery.join()
      let drained = pool.closeForMigration(timeout: .seconds(2))
      #expect(joined && drained)
    }
  }

  @Test func p2bB12QueuedCloseAndGuardRefusalCleanlySettle() throws {
    try P2BNativeFixture.withFixture { f in
      let pool = try f.pool()
      let probe = try f.poolProbe(pool)
      pool.close()
      p2bAnyRefusal {
        _ = try pool.readAccountSessionNativeFacts(memoryCheck: AccountSessionComparisonCheck {})
      }
      let sample = probe.snapshot()
      let beforeWaitRefused =
        sample.waitStart == nil && !sample.leaseEntered && !sample.slotSignalled
        && sample.commandStarts.allSatisfy { $0 == 0 }
      #expect(beforeWaitRefused)
    }
    try P2BNativeFixture.withFixture { f in
      let pool = try f.pool()
      let hold = f.resources.hold()
      let holder = f.resources.worker {
        try pool.withConnection { c in
          try p2bOne(c); return hold.wait()
        }
      }
      try p2bRequire(p2bPoll { hold.entered })
      let probe = try f.poolProbe(pool)
      let reader = f.resources.worker {
        p2bAnyRejected {
          _ = try pool.readAccountSessionNativeFacts(memoryCheck: AccountSessionComparisonCheck {})
        }
      }
      try p2bRequire(p2bPoll { probe.snapshot().waitStart != nil })
      pool.close()
      hold.release()
      let settled = holder.join() && reader.join()
      let sample = probe.snapshot()
      let closed = !sample.leaseEntered && sample.slotSignalled && sample.commandStarts.allSatisfy { $0 == 0 }
      #expect(settled && closed)
    }
    for ordinal in [1, 2] {
      try P2BNativeFixture.withFixture { f in
        let pool = try f.pool()
        let probe = try f.poolProbe(pool)
        let calls = Mutex(0)
        let check = AccountSessionComparisonCheck {
          let value = calls.withLock {
            $0 += 1; return $0
          }
          if value == ordinal { throw P2BSensitiveFailure() }
        }
        p2bAnyRefusal { _ = try pool.readAccountSessionNativeFacts(memoryCheck: check) }
        let sample = probe.snapshot()
        let cleanup =
          sample.leaseEntered && sample.leaseLeft && sample.slotSignalled
          && sample.commandStarts.allSatisfy { $0 == 0 }
          && sample.refusedGuards == UInt(1 << (ordinal - 1))
        #expect(cleanup)
        let finiteOldAbsent = p2bPoll { (try? f.sessions(application: f.lastPoolApplication)) == 0 }
        #expect(finiteOldAbsent)
      }
    }
  }

  @Test func p2bB13FreshConnectionDiscardsAndExplicitFinishPrecedesLeave() throws {
    try P2BNativeFixture.withFixture { f in
      let pool = try f.pool()
      let oldPID = try f.sessionPID(application: f.lastPoolApplication)
      let probe = try f.poolProbe(pool, phase: .beforeFreshFinish)
      let reader = f.resources.worker {
        _ = try pool.readAccountSessionNativeFacts(memoryCheck: AccountSessionComparisonCheck {}); return true
      }
      try p2bRequire(p2bPoll { probe.snapshot().holdEntered })
      try p2bRequire(p2bPoll { (try? f.sessions(application: f.lastPoolApplication)) == 1 })
      let freshPID = try f.sessionPID(application: f.lastPoolApplication)
      let distinct = oldPID != freshPID
      let leaseHeld = !pool.closeForMigration(timeout: .zero)
      #expect(distinct && leaseHeld)
      probe.releaseHold()
      let settled = reader.join()
      p2bSuccessfulSample(probe.snapshot())
      let absent = p2bPoll { (try? f.sessions(application: f.lastPoolApplication)) == 0 }
      let drained = pool.closeForMigration(timeout: .seconds(2))
      #expect(settled && absent && drained)
    }
    try P2BNativeFixture.withFixture { f in
      try f.withRole(limit: 2) { role, pool in
        let blocker = try f.roleConnection(role)
        try f.sql("ALTER ROLE \(Rows.quote(role)) CONNECTION LIMIT 1")
        let realTwo =
          try f.scalar(
            "SELECT count(*) AS n FROM pg_stat_activity WHERE datname=$1 AND usename=$2",
            [f.endpoint.database, role]) == 2
        #expect(realTwo)
        let probe = try f.poolProbe(pool)
        p2bAnyRefusal {
          _ = try pool.readAccountSessionNativeFacts(memoryCheck: AccountSessionComparisonCheck {})
        }
        let noFallback =
          probe.snapshot().commandStarts.allSatisfy { $0 == 0 }
          && probe.snapshot().leaseLeft && probe.snapshot().slotSignalled
        #expect(noFallback)
        withExtendedLifetime(blocker) {}
      }
    }
    // G3/decode/rollback failures below all require the same explicit finish/leave/signal oracle.
    for mode in [0, 1, 2] {
      try P2BNativeFixture.withFixture { f in
        if mode == 1 { try f.sql("ALTER TABLE public.\"hubLink\" ALTER COLUMN url DROP NOT NULL") }
        let probe = try f.probe(phase: .beforeFreshFinish)
        let calls = Mutex(0)
        let check = AccountSessionComparisonCheck {
          let n = calls.withLock {
            $0 += 1; return $0
          }
          if (mode == 0 && n == 4) || (mode == 2 && n == 9) { throw P2BSensitiveFailure() }
        }
        let reader = f.resources.worker { p2bRejected { _ = try f.capture(check: check) } }
        try p2bRequire(p2bPoll { probe.snapshot().holdEntered })
        let during = probe.snapshot()
        let notFinished = during.leaseEntered && !during.leaseLeft && !during.freshFinishReturned
        #expect(notFinished)
        probe.releaseHold()
        let settled = reader.join()
        #expect(settled)
        p2bCleanupSample(probe.snapshot())
      }
    }
  }

  @Test func p2bB14RealReadOnlyCommandsBudgetsAndLockWait() throws {
    for (phase, command) in [
      (AccountSessionComparisonPhase.afterBeginBeforeG4, "BEGIN ISOLATION LEVEL READ COMMITTED READ ONLY"),
      (.afterLockBudgetBeforeG5, "SET LOCAL lock_timeout='2s'"),
      (.afterStatementBudgetBeforeG6, "SET LOCAL statement_timeout='2s'"),
      (.afterFactsBeforeG7, p2bFixedFactsSQL),
      (.afterRollbackBeforeG8, "ROLLBACK"),
    ] {
      try P2BNativeFixture.withFixture { f in
        let before = try f.image()
        let probe = try f.probe(phase: phase)
        let reader = f.resources.worker {
          _ = try f.capture(); return true
        }
        try p2bRequire(p2bPoll { probe.snapshot().holdEntered })
        let activity = try f.activity()
        let query = activity.text("query") ?? ""
        let expected =
          phase == .afterFactsBeforeG7
          ? !query.isEmpty && query.utf8.count <= command.utf8.count
            && command.utf8.prefix(query.utf8.count).elementsEqual(query.utf8)
          : query == command
        let state =
          activity.text("state") == (phase == .afterRollbackBeforeG8 ? "idle" : "idle in transaction")
        #expect(expected && state)
        probe.releaseHold()
        let settled = reader.join()
        #expect(settled)
        p2bSuccessfulSample(probe.snapshot())
        let unchanged = try f.image() == before
        #expect(unchanged)
      }
    }
    try P2BNativeFixture.withFixture { f in
      let before = try f.image()
      try f.sql("BEGIN; LOCK TABLE public.\"hubLink\" IN ACCESS EXCLUSIVE MODE")
      defer { _ = try? f.inspector.execute("ROLLBACK") }
      let probe = try f.probe()
      let reader = f.resources.worker { p2bRejected { _ = try f.capture() } }
      let actualWait = p2bPoll { (try? f.relationWait()) == true }
      #expect(actualWait)
      let settled = reader.join()
      let sample = probe.snapshot()
      let budgetInstalled =
        sample.commandAcknowledgements[1] == 1 && sample.commandAcknowledgements[2] == 1
        && sample.commandStarts[3] == 1 && sample.rollbackAttempts == 1
      #expect(settled && budgetInstalled)
      p2bCleanupSample(sample)
      try f.sql("ROLLBACK")
      _ = try f.capture()
      let unchanged = try f.image() == before
      #expect(unchanged)
    }
  }

  @Test func p2bB15BeginReadRollbackAndEachGuardFailureYieldNoSnapshot() throws {
    for guardNumber in 0...9 {
      try P2BNativeFixture.withFixture { f in
        let probe = try f.probe()
        let calls = P2BCheckCounter()
        let check = AccountSessionComparisonCheck {
          let n = calls.increment()
          if n == guardNumber + 1 { throw P2BSensitiveFailure() }
        }
        p2bRefusal { _ = try f.capture(check: check) }
        let sample = probe.snapshot()
        let callsStop = calls.read() == guardNumber + 1
        let starts = sample.commandStarts
        let expectedNormal = guardNumber <= 3 ? 0 : min(guardNumber - 3, 4)
        let normalCount = starts[0...3].reduce(0, +) == UInt(expectedNormal)
        let rollbackOnce = sample.rollbackAttempts == (guardNumber >= 4 ? 1 : 0)
        let refusedBit =
          guardNumber >= 1 && guardNumber <= 8
          ? sample.refusedGuards == UInt(1 << (guardNumber - 1)) : sample.refusedGuards == 0
        #expect(callsStop && normalCount && rollbackOnce && refusedBit)
        if guardNumber >= 3 { p2bCleanupSample(sample) }
      }
    }
    for (setting, phase, beginACK, rollbackACK) in [
      ("idle_session_timeout", AccountSessionComparisonPhase.afterConnectBeforeG3, UInt(0), UInt(0)),
      ("idle_in_transaction_session_timeout", .afterFactsBeforeG7, UInt(1), UInt(0)),
    ] {
      try P2BNativeFixture.withFixture { f in
        try f.sql("ALTER DATABASE \(Rows.quote(f.endpoint.database)) SET \(setting)='1s'")
        defer {
          _ = try? f.inspector.execute("ALTER DATABASE \(Rows.quote(f.endpoint.database)) RESET \(setting)")
        }
        let probe = try f.probe(phase: phase)
        let reader = f.resources.worker { p2bRejected { _ = try f.capture() } }
        try p2bRequire(p2bPoll { probe.snapshot().holdEntered })
        try p2bRequire(p2bPoll { (try? f.sessions(application: "b4app")) == 1 })
        let pid = try f.sessionPID(application: "b4app")
        let serverEnded = p2bPoll(seconds: 6) {
          (try? f.scalar(
            "SELECT count(*) AS n FROM pg_stat_activity WHERE datname=$1 AND pid=$2::integer",
            [f.endpoint.database, String(pid)])) == 0
        }
        let withinHold = !probe.snapshot().holdExpired
        #expect(serverEnded && withinHold)
        probe.releaseHold()
        let settled = reader.join()
        let sample = probe.snapshot()
        let acks =
          sample.commandAcknowledgements[0] == beginACK
          && sample.rollbackAcknowledgements == rollbackACK && sample.rollbackAttempts == 1
        let expectedStarts: [UInt] = setting == "idle_session_timeout" ? [1, 0, 0, 0, 1] : [1, 1, 1, 1, 1]
        let stoppedNormally = sample.commandStarts == expectedStarts
        #expect(settled && acks && stoppedNormally)
        p2bCleanupSample(sample)
      }
    }
    try P2BNativeFixture.withFixture { f in
      try f.withRole { _, pool in
        try f.sql("REVOKE SELECT ON public.\"hubLink\" FROM PUBLIC")
        try f.sql("REVOKE SELECT ON public.\"hubLink\" FROM \(Rows.quote(f.activeRole))")
        let probe = try f.poolProbe(pool)
        p2bAnyRefusal {
          _ = try pool.readAccountSessionNativeFacts(memoryCheck: AccountSessionComparisonCheck {})
        }
        let actualReadFailure =
          probe.snapshot().commandStarts[3] == 1 && probe.snapshot().rollbackAttempts == 1
          && probe.snapshot().resultClears[3] == 1 && probe.snapshot().factsDecoded == 0
          && probe.snapshot().rollbackAcknowledgements == 1
        #expect(actualReadFailure)
        p2bCleanupSample(probe.snapshot())
      }
    }
    try P2BNativeFixture.withFixture { f in
      let probe = try f.probe(phase: .beforeFreshFinish)
      let reader = f.resources.worker { p2bRejected { _ = try f.capture() } }
      try p2bRequire(p2bPoll { probe.snapshot().holdEntered })
      // Let the original closed hold actually expire; cleanup must still finish and release.
      let expired = p2bPoll(seconds: 11) { probe.snapshot().holdExpired }
      probe.releaseHold()
      let terminal = reader.join()
      let sample = probe.snapshot()
      let noFabricatedSuccess =
        expired && terminal && sample.holdExpired
        && sample.commandStarts == [1, 1, 1, 1, 1]
        && sample.commandAcknowledgements == [1, 1, 1, 1, 1]
        && sample.rollbackAttempts == 1 && sample.rollbackAcknowledgements == 1
      #expect(noFabricatedSuccess)
      p2bCleanupSample(sample)
    }
  }
}

private enum P2BFixtureFailure: Error { case incomplete }

// Test-owned exact normative statement; source review must bind the production literal to it.
private let p2bFixedFactsSQL = """
  SELECT pg_catalog.current_database()::pg_catalog.text AS database_name,
         (
           EXISTS (
             SELECT 1
             FROM pg_catalog.pg_class AS c
             JOIN pg_catalog.pg_namespace AS n ON n.oid = c.relnamespace
             WHERE c.oid = 'public."hubLink"'::pg_catalog.regclass
               AND n.nspname = 'public'
               AND c.relname = 'hubLink'
               AND c.relkind = 'r'
               AND NOT c.relrowsecurity
               AND NOT c.relforcerowsecurity
               AND (
                 SELECT pg_catalog.count(*)
                 FROM (
                   VALUES ('id'::pg_catalog.text, 23::pg_catalog.oid),
                          ('url'::pg_catalog.text, 25::pg_catalog.oid),
                          ('deviceId'::pg_catalog.text, 25::pg_catalog.oid),
                          ('joinedAt'::pg_catalog.text, 25::pg_catalog.oid),
                          ('tokenRef'::pg_catalog.text, 25::pg_catalog.oid)
                 ) AS wanted(name, type_oid)
                 JOIN pg_catalog.pg_attribute AS a
                   ON a.attrelid = c.oid AND a.attname = wanted.name
                 WHERE a.attnum > 0
                   AND NOT a.attisdropped
                   AND a.atttypid = wanted.type_oid
                   AND a.attnotnull
               ) = 5
               AND EXISTS (
                 SELECT 1
                 FROM pg_catalog.pg_constraint AS p
                 JOIN pg_catalog.pg_index AS i
                   ON i.indexrelid = p.conindid AND i.indrelid = c.oid
                 JOIN pg_catalog.pg_attribute AS a
                   ON a.attrelid = c.oid AND a.attname = 'id'
                 WHERE p.conrelid = c.oid
                   AND p.contype = 'p'
                   AND p.convalidated
                   AND pg_catalog.array_length(p.conkey, 1) = 1
                   AND p.conkey[1] = a.attnum
                   AND a.attnum > 0
                   AND NOT a.attisdropped
                   AND a.atttypid = 23::pg_catalog.oid
                   AND a.attnotnull
                   AND i.indisprimary
                   AND i.indisunique
                   AND i.indisvalid
                   AND i.indisready
                   AND i.indislive
                   AND i.indnkeyatts = 1
                   AND i.indkey[0] = a.attnum
                   AND i.indexprs IS NULL
                   AND i.indpred IS NULL
               )
           )
         )::pg_catalog.bool AS schema_ok,
         l.id AS native_link_id,
         l.url AS native_url,
         l."deviceId" AS native_device,
         l."joinedAt" AS native_joined,
         l."tokenRef" AS native_reference
  FROM (SELECT 1) AS singleton
  LEFT JOIN public."hubLink" AS l ON true
  """

private let p2bAbsentExpressions = [
  "'fixture'::pg_catalog.text AS database_name",
  "true::pg_catalog.bool AS schema_ok",
  "NULL::pg_catalog.int4 AS native_link_id",
  "NULL::pg_catalog.text AS native_url",
  "NULL::pg_catalog.text AS native_device",
  "NULL::pg_catalog.text AS native_joined",
  "NULL::pg_catalog.text AS native_reference",
]
private let p2bLinkedExpressions = [
  "'fixture'::pg_catalog.text AS database_name",
  "true::pg_catalog.bool AS schema_ok",
  "1::pg_catalog.int4 AS native_link_id",
  "'https://p2b.invalid'::pg_catalog.text AS native_url",
  "'device'::pg_catalog.text AS native_device",
  "'joined'::pg_catalog.text AS native_joined",
  "'secret:fixture'::pg_catalog.text AS native_reference",
]

private func p2bSQL(_ expressions: [String]) -> String {
  "SELECT " + expressions.joined(separator: ",\n       ")
}

private func p2bField(_ label: String?, _ oid: UInt32, _ bytes: [UInt8]?) -> AccountSessionRawField {
  AccountSessionRawField(
    label: label, oid: oid, isNull: bytes == nil ? 1 : 0,
    length: Int32(bytes?.count ?? 0), bytes: bytes)
}

private func p2bRawFields(linked: Bool) -> [AccountSessionRawField] {
  let labels = [
    "database_name", "schema_ok", "native_link_id", "native_url", "native_device", "native_joined",
    "native_reference",
  ]
  let oids: [UInt32] = [25, 16, 23, 25, 25, 25, 25]
  let values: [String?] =
    linked
    ? ["fixture", "t", "1", "https://p2b.invalid", "device", "joined", "secret:fixture"]
    : ["fixture", "t", nil, nil, nil, nil, nil]
  return labels.indices.map { p2bField(labels[$0], oids[$0], values[$0].map { Array($0.utf8) }) }
}

private func p2bDecoderRefusal(_ raw: AccountSessionRawResult) {
  let refused = p2bAnyRejected { _ = try AccountSessionFactsDecoder.decode(raw) }
  #expect(refused)
}

extension P2BNativeFixture {
  private func withNativeHandle<T>(_ body: (LibPQ.Conn) throws -> T) throws -> T {
    guard let connection = lib.connectdb(Self.connectionString(endpoint, application: "p2b_raw_result"))
    else {
      throw P2BFixtureFailure.incomplete
    }
    defer { lib.finish(connection) }
    guard lib.status(connection) == LibPQ.connectionOK else { throw P2BFixtureFailure.incomplete }
    return try body(connection)
  }

  private func withNativeResult<T>(
    _ connection: LibPQ.Conn, _ sql: String,
    _ body: (LibPQ.Result) throws -> T
  ) throws -> T {
    guard let result = lib.exec(connection, sql) else { throw P2BFixtureFailure.incomplete }
    // The test owns exactly one clear, including production decoder refusal.
    defer { lib.clear(result) }
    guard lib.resultStatus(result) == LibPQ.tuplesOK else { throw P2BFixtureFailure.incomplete }
    return try body(result)
  }

  func nativeBytes(_ sql: String, column: Int32) throws -> [UInt8] {
    try withNativeHandle { connection in
      try withNativeResult(connection, sql) { result in
        guard lib.ntuples(result) == 1, lib.nfields(result) > column,
          lib.getisnull(result, 0, column) == 0, lib.getlength(result, 0, column) >= 0,
          let pointer = lib.getvalue(result, 0, column)
        else { throw P2BFixtureFailure.incomplete }
        return Array(UnsafeRawBufferPointer(start: pointer, count: Int(lib.getlength(result, 0, column))))
      }
    }
  }

  func nativeResults() throws {
    try withNativeHandle { connection in
      try withNativeResult(connection, p2bFixedFactsSQL) { result in
        let labels = [
          "database_name", "schema_ok", "native_link_id", "native_url", "native_device", "native_joined",
          "native_reference",
        ]
        let oids: [UInt32] = [25, 16, 23, 25, 25, 25, 25]
        try p2bRequire(lib.ntuples(result) == 1 && lib.nfields(result) == 7)
        let metadata = labels.indices.allSatisfy { index in
          guard let pointer = lib.fname(result, Int32(index)), let value = String(validatingCString: pointer)
          else { return false }
          return value.utf8.elementsEqual(labels[index].utf8)
            && lib.ftype(result, Int32(index)) == oids[index]
        }
        #expect(metadata)
        let facts = try AccountSessionFactsDecoder.decodeNative(result, lib: lib)
        let actualDatabaseAndAbsence =
          facts.databaseName.utf8.elementsEqual(endpoint.database.utf8) && !p2bFactsLinked(facts)
        #expect(actualDatabaseAndAbsence)
      }
      for expressions in [p2bAbsentExpressions, p2bLinkedExpressions] {
        try withNativeResult(connection, p2bSQL(expressions)) { result in
          let labels = [
            "database_name", "schema_ok", "native_link_id", "native_url", "native_device", "native_joined",
            "native_reference",
          ]
          let oids: [UInt32] = [25, 16, 23, 25, 25, 25, 25]
          let shape = lib.ntuples(result) == 1 && lib.nfields(result) == 7
          try p2bRequire(shape)
          let correctMetadata = labels.indices.allSatisfy { index in
            guard let label = lib.fname(result, Int32(index)), let string = String(validatingCString: label)
            else { return false }
            return string.utf8.elementsEqual(labels[index].utf8)
              && lib.ftype(result, Int32(index)) == oids[index]
          }
          #expect(correctMetadata)
          let decoded = try AccountSessionFactsDecoder.decodeNative(result, lib: lib)
          let correctBranch = p2bFactsLinked(decoded) == (expressions == p2bLinkedExpressions)
          let databaseBytes = decoded.databaseName.utf8.elementsEqual("fixture".utf8)
          #expect(correctBranch && databaseBytes)
          if expressions == p2bAbsentExpressions {
            let actualNull = (2..<7).allSatisfy {
              lib.getisnull(result, 0, Int32($0)) == 1 && lib.getlength(result, 0, Int32($0)) == 0
            }
            #expect(actualNull)
          }
        }
      }
      var vectors: [String] = []
      vectors.append(p2bSQL(p2bAbsentExpressions) + " WHERE false")
      vectors.append(p2bSQL(p2bAbsentExpressions) + " UNION ALL " + p2bSQL(p2bAbsentExpressions))
      vectors.append(p2bSQL(Array(p2bAbsentExpressions.prefix(6))))
      vectors.append(p2bSQL(p2bAbsentExpressions + ["NULL::pg_catalog.text AS unexpected"]))
      for (index, expression) in [
        (1, "true::pg_catalog.bool AS database_name"),
        (0, "'fixture'::pg_catalog.text AS database"),
        (0, "'fixture'::pg_catalog.text AS \"datab\u{00e1}se_name\""),
        (0, "pg_catalog.current_database() AS database_name"),
        (0, "NULL::pg_catalog.text AS database_name"),
        (1, "NULL::pg_catalog.bool AS schema_ok"),
        (1, "false::pg_catalog.bool AS schema_ok"),
        (3, "'https://p2b.invalid'::pg_catalog.text AS native_url"),
      ] {
        var expressions = p2bAbsentExpressions
        expressions[index] = expression
        vectors.append(p2bSQL(expressions))
      }
      var swapped = p2bAbsentExpressions
      swapped.swapAt(0, 1)
      vectors.append(p2bSQL(swapped))
      for (index, expression) in [
        (2, "'1'::pg_catalog.text AS native_link_id"),
        (4, "NULL::pg_catalog.text AS native_device"),
        (2, "2::pg_catalog.int4 AS native_link_id"),
        (4, "''::pg_catalog.text AS native_device"),
        (6, "''::pg_catalog.text AS native_reference"),
        (6, "'wrong:fixture'::pg_catalog.text AS native_reference"),
      ] {
        var expressions = p2bLinkedExpressions
        expressions[index] = expression
        vectors.append(p2bSQL(expressions))
      }
      for vector in vectors {
        try withNativeResult(connection, vector) { result in
          let refused = p2bAnyRejected { _ = try AccountSessionFactsDecoder.decodeNative(result, lib: lib) }
          #expect(refused)
        }
      }
      var unicode = p2bLinkedExpressions
      unicode[4] = "'d\u{00e9}'::pg_catalog.text AS native_device"
      try withNativeResult(connection, p2bSQL(unicode)) { result in
        let facts = try AccountSessionFactsDecoder.decodeNative(result, lib: lib)
        let validUnicode = p2bFactsLinked(facts) && lib.getlength(result, 0, 4) == 3
        #expect(validUnicode)
      }
      guard let commandResult = lib.exec(connection, "BEGIN READ ONLY") else {
        throw P2BFixtureFailure.incomplete
      }
      do {
        defer { lib.clear(commandResult) }
        defer { if let rollback = lib.exec(connection, "ROLLBACK") { lib.clear(rollback) } }
        let actualCommand = lib.resultStatus(commandResult) == LibPQ.commandOK
        #expect(actualCommand)
        let refused = p2bAnyRejected {
          _ = try AccountSessionFactsDecoder.decodeNative(commandResult, lib: lib)
        }
        #expect(refused)
      }
      try withNativeResult(
        connection,
        "SELECT pg_catalog.current_database(), pg_catalog.current_database()::pg_catalog.text, ''::pg_catalog.text, NULL::pg_catalog.text"
      ) { result in
        let actualOID = lib.ftype(result, 0) == 19 && lib.ftype(result, 1) == 25
        let distinctNull =
          lib.getisnull(result, 0, 2) == 0 && lib.getlength(result, 0, 2) == 0
          && lib.getisnull(result, 0, 3) == 1 && lib.getlength(result, 0, 3) == 0
        #expect(actualOID && distinctNull)
      }
      var empty = p2bLinkedExpressions
      empty[4] = "''::pg_catalog.text AS native_device"
      try withNativeResult(connection, p2bSQL(empty)) { result in
        let realEmpty = lib.getisnull(result, 0, 4) == 0 && lib.getlength(result, 0, 4) == 0
        #expect(realEmpty)
        let refused = p2bAnyRejected { _ = try AccountSessionFactsDecoder.decodeNative(result, lib: lib) }
        #expect(refused)
      }
    }
  }

  func pureResults() throws {
    let absent = p2bRawFields(linked: false)
    let linked = p2bRawFields(linked: true)
    let validAbsent = try AccountSessionFactsDecoder.decode(
      AccountSessionRawResult(rowCount: 1, fieldCount: 7, fields: absent))
    let validLinked = try AccountSessionFactsDecoder.decode(
      AccountSessionRawResult(rowCount: 1, fieldCount: 7, fields: linked))
    let valid = !p2bFactsLinked(validAbsent) && p2bFactsLinked(validLinked)
    #expect(valid)
    for count: Int32 in [-1, 0, 2] {
      p2bDecoderRefusal(AccountSessionRawResult(rowCount: count, fieldCount: 7, fields: absent))
    }
    for count: Int32 in [6, 8] {
      p2bDecoderRefusal(AccountSessionRawResult(rowCount: 1, fieldCount: count, fields: absent))
    }
    p2bDecoderRefusal(AccountSessionRawResult(rowCount: 1, fieldCount: 7, fields: Array(absent.prefix(6))))
    p2bDecoderRefusal(AccountSessionRawResult(rowCount: 1, fieldCount: 7, fields: absent + [absent[0]]))
    for index in absent.indices {
      var fields = absent
      let field = fields[index]
      fields[index] = AccountSessionRawField(
        label: field.label, oid: field.oid == 25 ? 23 : 25,
        isNull: field.isNull, length: field.length, bytes: field.bytes)
      p2bDecoderRefusal(AccountSessionRawResult(rowCount: 1, fieldCount: 7, fields: fields))
    }
    var badFields: [(Int, AccountSessionRawField)] = [
      (0, p2bField(nil, 25, Array("fixture".utf8))),
      (0, p2bField("database", 25, Array("fixture".utf8))),
      (1, p2bField("database_name", 16, [116])),
      (0, p2bField("datab\u{00e1}se_name", 25, Array("fixture".utf8))),
      (2, p2bField("native_link_id", 25, nil)),
      (
        0,
        AccountSessionRawField(
          label: "database_name", oid: 25, isNull: -1, length: 7, bytes: Array("fixture".utf8))
      ),
      (
        0,
        AccountSessionRawField(
          label: "database_name", oid: 25, isNull: 2, length: 7, bytes: Array("fixture".utf8))
      ),
      (0, AccountSessionRawField(label: "database_name", oid: 25, isNull: 0, length: -1, bytes: [])),
      (2, AccountSessionRawField(label: "native_link_id", oid: 23, isNull: 1, length: 1, bytes: nil)),
      (2, AccountSessionRawField(label: "native_link_id", oid: 23, isNull: 1, length: 0, bytes: [])),
      (0, AccountSessionRawField(label: "database_name", oid: 25, isNull: 0, length: 0, bytes: nil)),
      (
        0,
        AccountSessionRawField(
          label: "database_name", oid: 25, isNull: 0, length: 6, bytes: Array("fixture".utf8))
      ),
      (0, p2bField("database_name", 25, [255])),
      (0, p2bField("database_name", 25, [0])),
      (0, p2bField("database_name", 25, [])),
      (1, p2bField("schema_ok", 16, [])),
      (1, p2bField("schema_ok", 16, Array("true".utf8))),
      (1, p2bField("schema_ok", 16, [102])),
      (0, p2bField("database_name", 25, nil)),
      (1, p2bField("schema_ok", 16, nil)),
    ]
    for index in 2..<7 {
      badFields.append((index, p2bField(absent[index].label, absent[index].oid, Array("partial".utf8))))
    }
    for (index, value) in badFields {
      var fields = absent; fields[index] = value
      p2bDecoderRefusal(AccountSessionRawResult(rowCount: 1, fieldCount: 7, fields: fields))
    }
    for index in 2..<7 {
      for value: [UInt8]? in [nil, [], [0], [255]] {
        var fields = linked
        fields[index] = p2bField(fields[index].label, fields[index].oid, value)
        p2bDecoderRefusal(AccountSessionRawResult(rowCount: 1, fieldCount: 7, fields: fields))
      }
    }
    for id in ["2", "01", "+1", " 1"] {
      var fields = linked; fields[2] = p2bField("native_link_id", 23, Array(id.utf8))
      p2bDecoderRefusal(AccountSessionRawResult(rowCount: 1, fieldCount: 7, fields: fields))
    }
  }
}

private final class P2BCheckCounter: Sendable {
  private let value = Mutex(0)
  func increment() -> Int {
    value.withLock {
      $0 += 1; return $0
    }
  }
  func read() -> Int { value.withLock { $0 } }
}

private struct P2BSensitiveFailure: Error, CustomStringConvertible {
  var description: String { "secret:sensitive-callback-https://private.invalid/SELECT" }
}

private func p2bRequire(_ value: Bool) throws {
  #expect(value)
  guard value else { throw P2BFixtureFailure.incomplete }
}

private func p2bFixed(_ error: any Error) -> Bool {
  guard let error = error as? WorkspaceError else { return false }
  return error.code == .internalError
    && error.message == "The account session comparison could not be completed."
    && error.details == nil && (error as NSError).userInfo[NSUnderlyingErrorKey] == nil
}

private func p2bRejected(_ action: () throws -> Void) -> Bool {
  do { try action(); return false } catch { return p2bFixed(error) }
}

private func p2bRefusal(_ action: () throws -> Void) {
  let fixedRefusal = p2bRejected(action)
  #expect(fixedRefusal)
}

private func p2bAnyRejected(_ action: () throws -> Void) -> Bool {
  do { try action(); return false } catch { return true }
}

private func p2bAnyRefusal(_ action: () throws -> Void) {
  let refused = p2bAnyRejected(action)
  #expect(refused)
}

private func p2bPrivacy<T>(_ value: T, name: String) {
  let privatePresentation =
    String(describing: value) == name + "(redacted)"
    && String(reflecting: value) == name + "(redacted)"
    && Mirror(reflecting: value).children.isEmpty
    && !(value is any Encodable) && !(T.self is any Decodable.Type)
  #expect(privatePresentation)
}

private func p2bPoll(seconds: Int = 2, _ condition: () -> Bool) -> Bool {
  let deadline = DispatchTime.now() + .seconds(seconds)
  while !condition(), DispatchTime.now() < deadline { Thread.sleep(forTimeInterval: 0.005) }
  return condition()
}

private func p2bOne(_ connection: PostgresConnection) throws {
  guard try connection.execute("SELECT 1 AS n").rows.first?.int("n") == 1 else {
    throw P2BFixtureFailure.incomplete
  }
}

private func p2bIsLinked(_ presence: AccountSessionPresence) -> Bool {
  switch presence {
  case .nativeAbsent: false
  case .nativeLinked: true
  }
}

private func p2bFactsLinked(_ facts: AccountSessionNativeFacts) -> Bool {
  if case .linked = facts.link { return true }
  return false
}

private func p2bCleanupSample(_ sample: AccountSessionComparisonTestSample) {
  let finish = sample.phaseSequence[AccountSessionComparisonPhase.afterFreshFinishBeforeLeaseLeave.rawValue]
  let leave = sample.phaseSequence[AccountSessionComparisonPhase.afterLeaseLeave.rawValue]
  let signal = sample.phaseSequence[AccountSessionComparisonPhase.afterSlotSignal.rawValue]
  let ordered =
    sample.freshFinishReturned && sample.leaseEntered && sample.leaseLeft
    && sample.slotSignalled && finish > 0 && leave > finish && signal > leave
  let exactlyOnce =
    sample.phaseCounts[AccountSessionComparisonPhase.afterFreshFinishBeforeLeaseLeave.rawValue] == 1
    && sample.phaseCounts[AccountSessionComparisonPhase.afterLeaseLeave.rawValue] == 1
    && sample.phaseCounts[AccountSessionComparisonPhase.afterSlotSignal.rawValue] == 1
  #expect(ordered && exactlyOnce)
}

private func p2bSuccessfulSample(_ sample: AccountSessionComparisonTestSample) {
  p2bCleanupSample(sample)
  let guards =
    sample.acceptedGuards == 255 && sample.refusedGuards == 0
    && sample.phaseCounts == Array(repeating: UInt(1), count: 13)
  let commands =
    sample.commandStarts == [1, 1, 1, 1, 1]
    && sample.commandAcknowledgements == [1, 1, 1, 1, 1]
    && sample.resultClears == [1, 1, 1, 1, 1]
    && sample.selectReturns == 1 && sample.factsDecoded == 1
    && sample.rollbackAttempts == 1 && sample.rollbackAcknowledgements == 1
  #expect(guards && commands)
  p2bPrivacy(sample, name: "AccountSessionComparisonTestSample")
}

private final class P2BHold: Sendable {
  private struct State { var entered = false; var released = false; var expired = false }
  private let cell = Mutex(State())
  private let semaphore = DispatchSemaphore(value: 0)
  let expiry: DispatchTime
  init(seconds: Int) { expiry = .now() + .seconds(seconds) }
  var entered: Bool { cell.withLock { $0.entered } }
  var expired: Bool { cell.withLock { $0.expired } }
  var held: Bool { cell.withLock { $0.entered && !$0.released && !$0.expired } }
  func wait() -> Bool {
    let released = cell.withLock {
      $0.entered = true; return $0.released
    }
    if released { return true }
    let okay = semaphore.wait(timeout: expiry) == .success
    if !okay { cell.withLock { $0.expired = true } }
    return okay
  }
  func release() {
    let first = cell.withLock {
      if $0.released { return false }; $0.released = true; return true
    }
    if first { semaphore.signal() }
  }
}

// A registered native worker's terminal marker is a driver completion observation. It is not
// physical native/process quiescence, and a timeout never authorizes resource removal.
private final class P2BWorker: Sendable {
  private let operation: Mutex<(@Sendable () throws -> Bool)?>
  private let result = Mutex<Bool?>(nil)
  private let joined = Mutex<Bool?>(nil)
  private let terminal = DispatchGroup()
  init(_ body: @escaping @Sendable () throws -> Bool) { operation = Mutex(body) }
  func start() {
    terminal.enter()
    Thread.detachNewThread { [self] in
      let action = operation.withLock {
        let previous = $0; $0 = nil; return previous
      }
      let value: Bool
      do { value = try action?() ?? false } catch { value = false }
      result.withLock { $0 = value }
      terminal.leave()
    }
  }
  func settle() -> Bool {
    if let previous = joined.withLock({ $0 }) { return previous }
    let returned = terminal.wait(timeout: .now() + .seconds(12)) == .success
    joined.withLock { $0 = returned }
    return returned
  }
  func join() -> Bool { settle() && result.withLock { $0 == true } }
}

private final class P2BResources: Sendable {
  private struct State {
    var holds: [P2BHold] = []
    var workers: [P2BWorker] = []
    var pools: [ConnectionPool] = []
    var poolProbes: [(ConnectionPool, AccountSessionComparisonTestProbe)] = []
    var databaseProbes: [(WorkspaceDatabase, AccountSessionComparisonTestProbe)] = []
  }
  private let cell = Mutex(State())
  func hold(seconds: Int = 10) -> P2BHold {
    let hold = P2BHold(seconds: seconds)
    cell.withLock { $0.holds.append(hold) }
    return hold
  }
  func worker(_ body: @escaping @Sendable () throws -> Bool) -> P2BWorker {
    let worker = P2BWorker(body)
    cell.withLock { $0.workers.append(worker) }
    worker.start()
    return worker
  }
  func pool(_ pool: ConnectionPool) { cell.withLock { $0.pools.append(pool) } }
  func probe(_ probe: AccountSessionComparisonTestProbe, pool: ConnectionPool) {
    cell.withLock { $0.poolProbes.append((pool, probe)) }
  }
  func probe(_ probe: AccountSessionComparisonTestProbe, database: WorkspaceDatabase) {
    cell.withLock { $0.databaseProbes.append((database, probe)) }
  }
  func finish() -> Bool {
    let state = cell.withLock { $0 }
    for hold in state.holds { hold.release() }
    for (_, probe) in state.poolProbes { probe.releaseHold() }
    for (_, probe) in state.databaseProbes { probe.releaseHold() }
    var settled = true
    for worker in state.workers {
      let joined = worker.settle()
      if joined { let outcome = worker.join(); #expect(outcome) }
      settled = joined && settled
    }
    guard settled else { return false }
    for (pool, probe) in state.poolProbes { _ = pool.clearAccountSessionComparisonTestProbe(probe) }
    for (database, probe) in state.databaseProbes {
      _ = database.clearAccountSessionComparisonTestProbe(probe)
    }
    for pool in state.pools {
      let drained = pool.closeForMigration(timeout: .seconds(2)); settled = drained && settled
    }
    return settled
  }
}

private final class P2BNativeFixture: Sendable {
  static let base = "https://p2b.invalid/Deployment"
  static let device = "device"
  static let reference = "secret:fixture"
  static let joined = "joined"
  let endpoint: PostgresEndpoint
  let binDir: String
  let database: WorkspaceDatabase
  let inspector: PostgresConnection
  let observer: PostgresConnection
  let lib: LibPQ
  let resources = P2BResources()
  private let applicationCell = Mutex("")
  private let roleCell = Mutex("")
  var lastPoolApplication: String { applicationCell.withLock { $0 } }
  var activeRole: String { roleCell.withLock { $0 } }

  private init(endpoint: PostgresEndpoint, binDir: String, root: String) throws {
    self.endpoint = endpoint
    self.binDir = binDir
    lib = try LibPQ.load(binDir: binDir)
    database = try WorkspaceDatabase(endpoint: endpoint, binDir: binDir, backupDirectory: root + "/backups")
    do {
      inspector = try PostgresConnection(
        lib: lib, connectionString: Self.connectionString(endpoint, application: "p2b_inspector"))
      observer = try PostgresConnection(
        lib: lib, connectionString: Self.connectionString(endpoint, application: "p2b_observer"))
    } catch {
      _ = database.closeForMigration(timeout: .seconds(2))
      throw P2BFixtureFailure.incomplete
    }
  }

  static func connectionString(
    _ endpoint: PostgresEndpoint, role: String = NSUserName(), application: String
  ) -> String {
    "host=\(endpoint.socketDir) port=\(endpoint.port) user=\(role) dbname=\(endpoint.database) application_name=\(application)"
  }

  static func withFixture(
    linked: Bool = false, ascii: Bool = false, _ body: (P2BNativeFixture) throws -> Void
  ) throws {
    do {
      let root =
        try AgentProtocolResourceFixture.physicalTemporaryDirectory() + "p2b-comparison-"
        + UUID().uuidString.lowercased()
      try PrivateFiles.ensurePrivateDirectory(root)
      let drained = try withNativeFixture(root: root, linked: linked, ascii: ascii, body)
      if drained {
        try FileManager.default.removeItem(atPath: root)
      } else {
        Issue.record("Comparison fixture resources did not settle; its private root was retained.")
      }
      try p2bRequire(drained)
    } catch {
      Issue.record("The native comparison fixture failed; private details were suppressed.")
      throw P2BFixtureFailure.incomplete
    }
  }

  private static func withNativeFixture(
    root: String, linked: Bool, ascii: Bool, _ body: (P2BNativeFixture) throws -> Void
  ) throws -> Bool {
    let endpoint = try AgentProtocolResourceFixture.endpoint()
    guard let binDir = endpoint.binDir else { throw P2BFixtureFailure.incomplete }
    if ascii {
      let admin = try PostgresConnection(
        lib: LibPQ.load(binDir: binDir),
        connectionString:
          "host=\(endpoint.socketDir) port=\(endpoint.port) user=\(NSUserName()) dbname=postgres application_name=p2b_ascii_admin"
      )
      // endpoint() has registered this newly empty owned DB; no session has opened it yet.
      try admin.execute("DROP DATABASE \(Rows.quote(endpoint.database))")
      try admin.execute(
        "CREATE DATABASE \(Rows.quote(endpoint.database)) TEMPLATE template0 ENCODING 'SQL_ASCII' LC_COLLATE 'C' LC_CTYPE 'C'"
      )
    }
    let fixture = try Self(endpoint: endpoint, binDir: binDir, root: root)
    let result = Result<Void, any Error> {
      if linked { try fixture.link() }
      try body(fixture)
    }
    let workersSettled = fixture.resources.finish()
    let drained = workersSettled && fixture.database.closeForMigration(timeout: .seconds(2))
    try result.get()
    return drained
  }

  func sql(_ sql: String, _ values: [String?] = []) throws { _ = try inspector.execute(sql, values) }
  func scalar(_ sql: String, _ values: [String?] = []) throws -> Int {
    guard let value = try inspector.execute(sql, values).rows.first?.int("n") else {
      throw P2BFixtureFailure.incomplete
    }
    return value
  }
  func link() throws {
    try database.saveHubLink(
      WorkspaceDatabase.HubLink(
        url: Self.base, deviceId: Self.device, deviceName: "fixture", tokenRef: Self.reference,
        orgSlug: "fixture", username: "fixture", joinedAt: Self.joined))
  }
  func capture(
    base: String = P2BNativeFixture.base, device: String = P2BNativeFixture.device,
    reference: String? = P2BNativeFixture.reference,
    check: AccountSessionComparisonCheck = AccountSessionComparisonCheck {}
  ) throws -> AccountSessionComparisonSnapshot {
    try database.captureAccountSessionComparison(
      accountID: "account", databaseName: endpoint.database,
      hubBase: base, deviceID: device, tokenReference: reference, memoryCheck: check)
  }
  func compare(_ original: AccountSessionComparisonSnapshot) throws {
    try database.compareOriginalAccountSession(
      expectedSnapshot: original, memoryCheck: AccountSessionComparisonCheck {})
  }
  func probe(phase: AccountSessionComparisonPhase? = nil) throws -> AccountSessionComparisonTestProbe {
    let probe = AccountSessionComparisonTestProbe(
      hold: phase.map { AccountSessionComparisonTestHold(phase: $0, expiry: .now() + .seconds(10)) })
    let installed = database.installAccountSessionComparisonTestProbe(probe)
    try p2bRequire(installed)
    resources.probe(probe, database: database)
    let refusedReplacement = !database.installAccountSessionComparisonTestProbe(
      AccountSessionComparisonTestProbe())
    let refusedWrongClear = !database.clearAccountSessionComparisonTestProbe(
      AccountSessionComparisonTestProbe())
    #expect(refusedReplacement && refusedWrongClear)
    return probe
  }
  func clear(_ probe: AccountSessionComparisonTestProbe) throws {
    try p2bRequire(database.clearAccountSessionComparisonTestProbe(probe))
  }
  func pool(size: Int = 1) throws -> ConnectionPool {
    let app = "p2b_pool_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    let pool = try ConnectionPool(
      lib: lib, connectionString: Self.connectionString(endpoint, application: app), size: size)
    resources.pool(pool)
    applicationCell.withLock { $0 = app }
    return pool
  }
  func poolProbe(
    _ pool: ConnectionPool, phase: AccountSessionComparisonPhase? = nil
  ) throws -> AccountSessionComparisonTestProbe {
    let probe = AccountSessionComparisonTestProbe(
      hold: phase.map { AccountSessionComparisonTestHold(phase: $0, expiry: .now() + .seconds(10)) })
    try p2bRequire(pool.installAccountSessionComparisonTestProbe(probe))
    resources.probe(probe, pool: pool)
    return probe
  }
  func sessions(application: String) throws -> Int {
    try scalar(
      "SELECT count(*) AS n FROM pg_stat_activity WHERE datname=$1 AND application_name=$2",
      [endpoint.database, application])
  }
  func sessionPID(application: String) throws -> Int {
    let rows = try inspector.execute(
      "SELECT pid AS n FROM pg_stat_activity WHERE datname=$1 AND application_name=$2",
      [endpoint.database, application]
    ).rows
    guard rows.count == 1, let value = rows.first?.int("n") else { throw P2BFixtureFailure.incomplete }
    return value
  }
  func activity() throws -> Row {
    let rows = try inspector.execute(
      "SELECT query,state FROM pg_stat_activity WHERE datname=$1 AND application_name='b4app'",
      [endpoint.database]
    ).rows
    guard rows.count == 1, let row = rows.first else { throw P2BFixtureFailure.incomplete }
    return row
  }
  func relationWait() throws -> Bool {
    try observer.execute(
      "SELECT count(*) AS n FROM pg_locks l JOIN pg_stat_activity a ON a.pid=l.pid WHERE a.datname=$1 AND a.application_name='b4app' AND l.relation='public.\"hubLink\"'::regclass AND l.mode='AccessShareLock' AND NOT l.granted",
      [endpoint.database]
    ).rows.first?.int("n") == 1
  }
  func requireCatalog() throws {
    let ordinary =
      try scalar(
        "SELECT count(*) AS n FROM pg_class WHERE oid='public.\"hubLink\"'::regclass AND relkind='r' AND NOT relrowsecurity AND NOT relforcerowsecurity"
      ) == 1
    let required =
      try scalar(
        "SELECT count(*) AS n FROM pg_attribute WHERE attrelid='public.\"hubLink\"'::regclass AND attnum>0 AND NOT attisdropped AND attnotnull AND ((attname='id' AND atttypid=23) OR (attname IN ('url','deviceId','joinedAt','tokenRef') AND atttypid=25))"
      ) == 5
    let primary =
      try scalar(
        "SELECT count(*) AS n FROM pg_constraint p JOIN pg_attribute a ON a.attrelid=p.conrelid AND a.attname='id' WHERE p.conrelid='public.\"hubLink\"'::regclass AND p.contype='p' AND p.convalidated AND p.conkey=ARRAY[a.attnum]::smallint[]"
      ) == 1
    try p2bRequire(ordinary && required && primary)
  }
  func image() throws -> [String: [Data]] {
    var result: [String: [Data]] = [:]
    for row in try inspector.execute(
      "SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY tablename"
    ).rows {
      guard let table = row.text("tablename") else { throw P2BFixtureFailure.incomplete }
      result[table] = try inspector.execute(
        "SELECT to_jsonb(t)::text AS value FROM public.\(Rows.quote(table)) t"
      ).rows.map {
        guard let text = $0.text("value") else { throw P2BFixtureFailure.incomplete }
        return Data(text.utf8)
      }.sorted { $0.lexicographicallyPrecedes($1) }
    }
    for row in try inspector.execute(
      "SELECT sequencename FROM pg_sequences WHERE schemaname='public' ORDER BY sequencename"
    ).rows {
      guard let name = row.text("sequencename") else { throw P2BFixtureFailure.incomplete }
      guard
        let text = try inspector.execute(
          "SELECT jsonb_build_object('last_value',last_value,'log_cnt',log_cnt,'is_called',is_called)::text AS value FROM public.\(Rows.quote(name))"
        ).rows.first?.text("value")
      else { throw P2BFixtureFailure.incomplete }
      result["sequence:" + name] = [Data(text.utf8)]
    }
    return result
  }
  func roleConnection(_ role: String) throws -> PostgresConnection {
    try PostgresConnection(
      lib: lib, connectionString: Self.connectionString(endpoint, role: role, application: "p2b_role_blocker")
    )
  }
  func withRole(limit: Int = -1, _ body: (String, ConnectionPool) throws -> Void) throws {
    let role = "p2b_role_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    try sql("CREATE ROLE \(Rows.quote(role)) LOGIN NOSUPERUSER NOBYPASSRLS CONNECTION LIMIT \(limit)")
    roleCell.withLock { $0 = role }
    // Register the exact owned role before grants/pool construction can fail.
    let operation = Result<Void, any Error> {
      try sql(
        "GRANT CONNECT ON DATABASE \(Rows.quote(endpoint.database)) TO \(Rows.quote(role)); GRANT USAGE ON SCHEMA public TO \(Rows.quote(role)); GRANT SELECT ON public.\"hubLink\" TO \(Rows.quote(role))"
      )
      let app = "p2b_role_pool_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
      let pool = try ConnectionPool(
        lib: lib, connectionString: Self.connectionString(endpoint, role: role, application: app), size: 1)
      resources.pool(pool)
      applicationCell.withLock { $0 = app }
      let liveProbe =
        try scalar(
          "SELECT count(*) AS n FROM pg_stat_activity WHERE datname=$1 AND usename=$2 AND application_name=$3",
          [endpoint.database, role, app]) == 1
      try p2bRequire(liveProbe)
      try body(role, pool)
    }
    let settled = resources.finish()
    let absent =
      settled
      && p2bPoll {
        (try? self.scalar("SELECT count(*) AS n FROM pg_stat_activity WHERE usename=$1", [role])) == 0
      }
    if absent {
      try sql("DROP OWNED BY \(Rows.quote(role)); DROP ROLE \(Rows.quote(role))")
      let gone = try scalar("SELECT count(*) AS n FROM pg_roles WHERE rolname=$1", [role]) == 0
      try p2bRequire(gone)
    } else {
      Issue.record("The exact comparison role was retained because its sessions did not settle.")
      throw P2BFixtureFailure.incomplete
    }
    try operation.get()
  }
}
