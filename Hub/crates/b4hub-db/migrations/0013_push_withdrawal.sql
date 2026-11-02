-- M8f APNs: withdrawing a notification once what it announced is over (its request was answered or
-- expired, its turn was read, or its thread was deleted). `0012_push.sql` is not edited, since
-- databases may already hold it.
--
-- `withdrawn_at` is set in the push transaction that ends the notification, whether or not a phone
-- has a token, so each notification is withdrawn at most once.
ALTER TABLE notifications_sent ADD COLUMN withdrawn_at timestamptz;

-- The outstanding notifications of a thread, for a read or a delete of that thread.
CREATE INDEX notifications_sent_outstanding ON notifications_sent (org_id, thread_id)
    WHERE withdrawn_at IS NULL;

-- The badge reads a user's turns and runtime requests by thread (the attention bands).
CREATE INDEX "turns_by_thread" ON "turns" (org_id, user_id, "threadId");
CREATE INDEX "runtimeRequests_by_thread" ON "runtimeRequests" (org_id, user_id, "threadId");
