import Foundation
import Observation
import Synchronization
import UIKit
import UserNotifications
import WidgetKit
import WorkspaceClient
import WorkspaceMirror
import WorkspaceProtocol
import WorkspaceSecrets
import WorkspaceSync
import WorkspaceUI
import os

/// The phone's account is the shared model's host (sign-in plan, Task 14): the model signs in,
/// onboards, logs out, and runs Settings → Account through it, exactly as the Mac's model does through
/// the coordinator. `MirrorAccount` already has every method `AccountHost` asks for.
extension MirrorAccount: @retroactive AccountHost {}

/// The phone's side of the hub (M8a, M8b, M8c, and the sign-in plan): the SQLite mirror, the phone's
/// account (`MirrorAccount`: the sign-in, the device token in the Keychain, and the sync that keeps the
/// mirror and the hub in step), and the relay that carries the phone's chat commands to the Mac and its
/// live events back. The shared `WorkspaceModel` reads and writes the mirror through a
/// `MirrorTransport`, exactly as the Mac's talks to the coordinator through its socket; the UI never
/// sees the store, the token, or the network.
///
/// The mirror's folder and the Keychain service are the flavour's (`PhoneFlavor`): prod keeps `b4app`,
/// so nothing moves; beta and local use `b4app-beta` and `b4app-local`, so a TestFlight build and an App
/// Store build on one phone never share a mirror or a token meant for another hub.
///
/// The relay's link is held only while the app is active (`RelayLifecycle`): background closes it, and
/// the next active opens it again with the same watched threads. The pull loop is paused between turns
/// (`MirrorAccount.suspendSync`) before the app is suspended, since iOS kills an app that is suspended
/// holding a lock on a file in the App Group container, and resumed on the next active.
///
/// Attention (M8f): the mirror lives in the flavour's App Group so the widget reads it (D-125), every
/// batch that touched threads or projects and every sign-in or sign-out reloads the widget's
/// timelines, the APNs token goes to the hub while signed in (D-122), and a thread link (a notification
/// tap, a widget row) opens its thread (D-124).
@MainActor @Observable final class MirrorHost {
  static let shared = MirrorHost()
  static let flavor = PhoneFlavor.current

  /// A fresh `MirrorTransport` over the shared store for each (re)connect of the model; the newest
  /// one receives the pull loop's batches. A transport is single use, so one is never handed out twice.
  static let transportProvider: WorkspaceModel.TransportProvider = {
    try await MirrorHost.shared.makeTransport()
  }

  /// Why the mirror could not be opened, if it could not.
  private(set) var storeError: String?
  /// Set when the mirror file is a schema this build cannot read but holds edits not yet uploaded: the
  /// file is kept as it is, nothing syncs, and Diagnostics and the status line say so.
  @ObservationIgnored private var unreadableReason: String?
  /// The pull loop's last outcome; `lastError` is set while the mirror is not keeping up with the hub.
  private(set) var syncStatus = MirrorSyncStatus()
  /// Set when the hub refused the relay's link (`unauthorized`, `revoked`): the link stays closed until
  /// this phone signs in again, and the banner says so.
  private(set) var relayRefused: String?

  @ObservationIgnored private let store: MirrorStore?
  @ObservationIgnored private let secrets: any SecretStore = KeychainSecretStore(
    service: MirrorHost.flavor.keychainService)
  /// The phone's account over the mirror; nil when the mirror could not be opened or read.
  @ObservationIgnored let account: MirrorAccount?
  @ObservationIgnored private var transport: MirrorTransport?
  /// The phone's link to the hub for chat (M8c), made while signed in; nil before, and after log-out.
  @ObservationIgnored private var relay: MirrorRelay?
  /// The token reference of the link the relay was made for.
  @ObservationIgnored private var relayTokenRef: String?
  /// The token reference of the link notifications were last set up for (the push token registered,
  /// the widget reloaded).
  @ObservationIgnored private var pushTokenRef: String?
  /// Whether the relay should be running, from the scene phase and the sign-in.
  @ObservationIgnored private var lifecycle = RelayLifecycle(enrolled: false)
  /// The relay's start and stop calls, chained so they reach it in the order they were decided.
  @ObservationIgnored private var relayControl: Task<Void, Never>?
  /// Watches the relay for the stops it makes on its own.
  @ObservationIgnored private var relayWatch: Task<Void, Never>?
  /// The copy for a refused link.
  static let relayRefusedMessage = SyncBanner.signInRequiredMessage
  /// The shell's model, once made.
  @ObservationIgnored private weak var model: WorkspaceModel?
  /// The sync's suspend and resume calls, chained (as the relay's are) so they reach it in the order
  /// the scene phases and background wakes decided them.
  @ObservationIgnored private var syncControl: Task<Void, Never>?
  /// This phone's APNs token, hex-encoded. Kept in memory only and never logged (D-122).
  @ObservationIgnored private(set) var pushToken: String?
  /// A thread a link asked for before `makeModel` made the model (a cold launch from a tap).
  @ObservationIgnored private var pendingOpen: String?
  /// Overlapping wakes share work, but a late arrival still requires a fresh catch-up cycle.
  @ObservationIgnored private let backgroundRefreshes = MirrorRefreshCoordinator()

  /// Numbers the sync's control calls in the order they were queued, and the last resume among them, so
  /// a suspend that a later resume has overtaken (a wake that stopped waiting for it) does nothing.
  @ObservationIgnored private var syncControlSerial = 0
  @ObservationIgnored private var lastResumeSerial = 0
  /// Set once a suspend has parked the loop, and cleared by the resume that lets it go again.
  @ObservationIgnored private var syncParked = false
  /// A moment the sync loop's next turn is known to begin after: its last report, or when it was let
  /// go after being parked. Nil until known.
  @ObservationIgnored private var turnStartsAfter: Date?
  /// The backstop judges only notifications delivered before this: a pull that began later has been
  /// applied since, so a request or turn the notification names is in the mirror if it exists at all.
  /// A younger notification may name a row the mirror has not pulled yet, which would read as ended.
  @ObservationIgnored private var judgedThrough = Date.distantPast
  /// The backstop and the sign-out clearing, chained so they reach the notification center in order.
  @ObservationIgnored private var notificationWork: Task<Void, Never>?
  /// The throttled backstop's pending run, and when the last one began.
  @ObservationIgnored private var reconcileScheduled: Task<Void, Never>?
  /// A backstop was asked for and has not begun yet. Every request sets it and the run clears it as
  /// it begins, so it stays set while a throttled run is pending, after a suspend cancelled that run,
  /// or when the run found the loop parked; the suspend (or the next resume) then runs what is owed.
  @ObservationIgnored private var reconcileOwed = false
  @ObservationIgnored private var lastReconcileAt: ContinuousClock.Instant?
  /// The badge last set, so only a change is logged.
  @ObservationIgnored private var lastBadge: Int?

  private static let logger = Logger(subsystem: "com.cacheplane.b4app", category: "attention")
  /// How long a background wake waits for its fresh pull to reach the end of the feed.
  private static let backgroundWait: Duration = .seconds(8)
  /// How long a background wake waits for a queued suspend of the sync before resuming it anyway.
  private static let queuedSuspendWait: Duration = .seconds(3)
  /// The backstop runs at most once in this interval (streaming sends batches in bursts).
  private static let reconcileInterval: Duration = .seconds(1)

  /// Which APNs endpoint this build's token belongs to (M8f APNs design, "The phone"): the Simulator
  /// is `sandbox`; on a device, the embedded provisioning profile's `aps-environment`, or `production`
  /// when Apple stripped the profile (TestFlight, the App Store).
  private static var pushEnvironment: String {
    #if targetEnvironment(simulator)
      let isSimulator = true
    #else
      let isSimulator = false
    #endif
    let profile = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision")
      .flatMap { try? Data(contentsOf: $0) }
    return PushEnvironment.resolve(isSimulator: isSimulator, profile: profile)
  }

  private static var version: String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
  }

  /// Who the phone is signed in as (the account's own state, as the root and Settings read it).
  var accountStatus: AccountStatus.Result? { account?.accountStatus }

  /// Signed in (or onboarding): a link is stored.
  var isSignedIn: Bool { account?.link != nil }

  private init() {
    var opened: MirrorStore?
    var fromSnapshot = false
    var unreadable: String?
    var failure: String?
    var directory: URL?
    do {
      let folder = try Self.directory()
      directory = folder
      let path = folder.appendingPathComponent(MirrorLocation.fileName).path
      do {
        opened = try MirrorStore(path: path)
      } catch MirrorStoreError.needsRebuild(outboxEmpty: true) {
        // Nothing unsent is lost. The rebuilt file keeps the link and the sequence counter, and its
        // rows come from the hub's snapshot rather than a pull of the whole feed.
        opened = try MirrorStore.rebuild(path: path)
        fromSnapshot = true
      } catch let error as MirrorStoreError {
        // Unsent edits are in a file this build cannot read: keep it and do not sync. It can only
        // have been linked, so the shell shows over an empty mirror, with the reason in Diagnostics.
        unreadable = error.description
      }
    } catch {
      failure = Self.describe(error)
    }
    // A mirror another flavour's build left in this folder is emptied before anything reads it, and
    // its token forgotten (it was kept under the same Keychain service).
    if let opened, let stale = MirrorAccount.discardForeignLink(in: opened, flavor: Self.flavor) {
      let keychain = KeychainSecretStore(service: Self.flavor.keychainService)
      Task { _ = try? await keychain.remove(stale) }
    }
    store = opened
    unreadableReason = unreadable
    storeError = unreadable ?? failure
    if let unreadable { syncStatus = MirrorSyncStatus(lastError: unreadable) }
    if let opened {
      account = MirrorAccount(
        store: opened, secrets: secrets,
        configuration: MirrorAccount.Configuration(
          hubURL: Self.flavor.hubURL, deviceName: UIDevice.current.name, flavor: Self.flavor),
        memory: MirrorDeviceMemory(url: directory?.appendingPathComponent("device.json")),
        onBatch: { batch in await MirrorHost.shared.publish(batch) },
        onSyncStatus: { status in await MirrorHost.shared.update(status) })
    } else {
      account = nil
    }
    account?.onChange = { status in MirrorHost.shared.accountChanged(status) }
    account?.onDevices = { MirrorHost.shared.refreshHostState() }
    // Launched in the background (a push's wake): no `.background` phase will come to pause the loop,
    // and a suspend queued after `startSync` would let the first turn run first. Mark the account
    // suspended before it starts, so the loop begins parked.
    let launchedInBackground = UIApplication.shared.applicationState == .background
    if launchedInBackground { account?.prepareSuspended() }
    if let account, let link = account.link {
      makeRelay(link)
      // The loop's first turn begins after this.
      turnStartsAfter = Date()
      account.startSync(fromSnapshot: fromSnapshot)
    }
    lifecycle = RelayLifecycle(enrolled: relay != nil, hasRelay: relay != nil)
    pushTokenRef = account?.link?.tokenRef
    // The suspend is also queued, ordered and under a background task as a `.background` phase's is,
    // so the app is not suspended before the parked loop reports idle.
    if launchedInBackground { controlSync(.suspend) }
  }

  /// The shared shell's model, with the phone's account as its host and the flavour's sign-in screen.
  func makeModel() -> WorkspaceModel {
    let model = WorkspaceModel(transportProvider: Self.transportProvider, accountSource: .host)
    model.signInConfiguration = SignInConfiguration(
      siteDomain: Self.flavor.siteDomain, appleSignIn: Self.flavor.appleSignIn, badge: Self.flavor.badge)
    model.accountHost = account
    self.model = model
    refreshHostState()
    if let id = pendingOpen {
      pendingOpen = nil
      model.requestOpenThread(id)
    }
    if isSignedIn { requestNotifications() }
    return model
  }

  /// `<the flavour's App Group container>/<flavour's folder>` (D-125), after moving a mirror (and the
  /// remembered devices) left in `<Application Support>/<flavour's folder>` by an earlier build; that
  /// old directory when the App Group is not available. Either is readable once the device has been
  /// unlocked after boot, so the pull loop and the widget work while the screen is locked.
  private static func directory() throws -> URL {
    let old = try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
    ).appendingPathComponent(flavor.directoryName, isDirectory: true)
    guard let appGroup = AppInfo.appGroup,
      let group = MirrorLocation.groupDirectory(appGroup: appGroup, folder: flavor.directoryName)
    else {
      logger.warning("the App Group container is unavailable; the mirror stays in Application Support")
      return try prepare(old)
    }
    do {
      switch try MirrorLocation.move(from: old, to: group) {
      case .nothingToMove: break
      case .moved: logger.notice("moved the mirror into the App Group")
      case .keptGroupCopy:
        logger.notice("kept the App Group's mirror; the older copy stays in Application Support")
      }
    } catch {
      // The main file moves last, and a failed move puts the side files it moved back, so while the main
      // file is still in the old directory that copy is the whole one.
      logger.error("the mirror could not move into the App Group: \(describe(error), privacy: .public)")
      let moved = group.appendingPathComponent(MirrorLocation.fileName).path
      let stayed = old.appendingPathComponent(MirrorLocation.fileName).path
      if !FileManager.default.fileExists(atPath: moved), FileManager.default.fileExists(atPath: stayed) {
        return try prepare(old)
      }
    }
    // The devices this phone had at each hub (`MirrorDeviceMemory`) follow the mirror, unless the
    // group already has its own; a failure only costs the hub reusing a device at the next sign-in.
    let memory = "device.json"
    let oldMemory = old.appendingPathComponent(memory)
    let newMemory = group.appendingPathComponent(memory)
    if FileManager.default.fileExists(atPath: oldMemory.path),
      !FileManager.default.fileExists(atPath: newMemory.path)
    {
      try? FileManager.default.moveItem(at: oldMemory, to: newMemory)
    }
    return try prepare(group)
  }

  /// Creates `directory` when missing and sets its protection to `completeUntilFirstUserAuthentication`.
  private static func prepare(_ directory: URL) throws -> URL {
    let protection: [FileAttributeKey: Any] = [
      .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
    ]
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: protection)
    try FileManager.default.setAttributes(protection, ofItemAtPath: directory.path)
    return directory
  }

  private func makeTransport() throws -> any WorkspaceTransport {
    let transport: MirrorTransport
    if let store {
      transport = MirrorTransport(
        store: store, version: Self.version, onLocalWrite: { Task { await MirrorHost.shared.nudge() } },
        relay: relay)
    } else if let unreadableReason {
      // An empty stand-in that answers reads, refuses writes, and puts the reason in Diagnostics.
      transport = MirrorTransport(
        store: try MirrorStore.inMemory(), version: Self.version, unavailable: unreadableReason)
    } else {
      throw WorkspaceError(.endpointUnavailable, storeError ?? "The mirror could not be opened.")
    }
    self.transport = transport
    return transport
  }

  // MARK: - The account

  /// The account changed (a sign-in, onboarding, a log-out, or the hub refusing the token). The relay
  /// follows the link first, so the model's next transport carries the new one; then the model.
  private func accountChanged(_ status: AccountStatus.Result) {
    let link = status.state == .signedOut ? nil : account?.link
    if link?.tokenRef != relayTokenRef {
      if let old = relay { retire(old) }
      // Down first, so a new relay is started even when the old one was running.
      _ = lifecycle.setEnrolled(false, hasRelay: false)
      if let link {
        makeRelay(link)
        control(lifecycle.setEnrolled(true, hasRelay: relay != nil))
      }
    }
    if status.state == .signedOut {
      syncStatus = MirrorSyncStatus()
      pendingOpen = nil
    }
    refreshHostState()
    model?.applyHostAccount(status)
    if link?.tokenRef != pushTokenRef {
      // A new sign-in asks for notifications (whose token then goes to its hub); a sign-out empties
      // the mirror, so the widget shows the unlinked glance.
      pushTokenRef = link?.tokenRef
      // Another sync's turns: the backstop waits for its reports before judging anything.
      turnStartsAfter = nil
      judgedThrough = .distantPast
      if link != nil {
        requestNotifications()
        registerPushToken()
      } else {
        // A phone whose log-out never reached the hub is still on its push list there; stop APNs
        // delivering (a title on the lock screen) to a phone nobody is signed in on. The next
        // sign-in's `requestNotifications()` registers again, after this call.
        UIApplication.shared.unregisterForRemoteNotifications()
        clearNotifications()
      }
      WidgetCenter.shared.reloadAllTimelines()
    }
  }

  /// Join a hub with a typed one-time enrollment code (an operator's hub): validates the URL before
  /// any request, enrolls as an `ios` device, and signs in. The code is not kept.
  func connect(url: String, code: String, deviceName: String) async throws {
    _ = try await phoneAccount().enroll(url: url, code: code, deviceName: deviceName)
  }

  /// A pairing link the person confirmed (D-066): signs a signed-out phone in, merges a phone-only
  /// account into the code's, or answers the switch question to ask (`MirrorAccount.pair`).
  func pair(_ link: PairLink, deviceName: String) async throws -> MirrorPairOutcome {
    try await phoneAccount().pair(link, deviceName: deviceName)
  }

  /// What a pairing link shows before anything is asked: "already paired" for this phone's own account's
  /// code, otherwise the question (`MirrorAccount.offer(for:)`, D-170). Spends nothing.
  func offer(for link: PairLink) async -> PairOffer {
    guard let account else { return .ask }
    return await account.offer(for: link)
  }

  /// The switch question was confirmed: log out, then enroll into the code's account.
  func switchAndPair(_ link: PairLink, deviceName: String) async throws {
    _ = try await phoneAccount().switchAndPair(link, deviceName: deviceName)
  }

  private func phoneAccount() throws -> MirrorAccount {
    guard let account else {
      throw WorkspaceError(.endpointUnavailable, storeError ?? "The mirror could not be opened.")
    }
    return account
  }

  /// From the mirror's devices table: no joined Mac left (the list's notice), and no Mac ever
  /// ("Connect your Mac"). Empty (not fetched yet) is neither, so a phone with a Mac never flashes it.
  private func refreshHostState() {
    model?.hostDisconnected = (try? store?.devices())?.hostDisconnected ?? false
    model?.accountHasNoMac = account?.hasNoMac ?? false
  }

  // MARK: - Attention (M8f)

  /// Asks to show notifications, then registers for remote ones whatever the answer: a background
  /// push still refreshes the mirror and the widget when alerts are off.
  func requestNotifications() {
    Task {
      do {
        _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [
          .alert, .sound, .badge,
        ])
      } catch {
        Self.logger.error("notification authorization failed: \(Self.describe(error), privacy: .public)")
      }
      UIApplication.shared.registerForRemoteNotifications()
    }
  }

  /// APNs gave this phone a token: keep it (hex, in memory) and send it to the hub while signed in.
  func received(pushToken token: Data) {
    pushToken = token.map { String(format: "%02x", $0) }.joined()
    registerPushToken()
  }

  /// Sends the token to the hub when there is one and the phone is signed in. A failure is logged
  /// without the token; the next registration (the next launch, or the next sign-in) tries again.
  private func registerPushToken() {
    guard let token = pushToken, let link = account?.link,
      let base = try? HubURL.validate(link.hubURL), let ref = SecretRef(rawValue: link.tokenRef),
      let bundleId = Bundle.main.bundleIdentifier
    else { return }
    let api = HTTPHubAPI(baseURL: base, token: { [secrets] in try await secrets.read(ref) })
    let environment = Self.pushEnvironment
    Task {
      do {
        try await api.registerPushToken(token, environment: environment, bundleId: bundleId)
      } catch {
        Self.logger.error("push token registration failed: \(Self.describe(error), privacy: .public)")
      }
    }
  }

  /// A thread link from a notification tap, a widget row, or `onOpenURL`. True when `url` is one (it
  /// is then handled here and never reaches pairing or sign-in); while signed out it is taken and
  /// does nothing.
  func handle(url: URL) -> Bool {
    guard let id = ThreadLink.threadId(from: url, scheme: AppInfo.urlScheme) else { return false }
    if isSignedIn { open(threadId: id) }
    return true
  }

  /// Opens a thread now, or once `makeModel` has made the model.
  func open(threadId: String) {
    if let model {
      model.requestOpenThread(threadId)
    } else {
      pendingOpen = threadId
    }
  }

  /// Whether the thread is open and in front of the owner, so a foreground notification for it is
  /// not shown.
  func isOnScreen(threadId: String) -> Bool {
    guard let model else { return false }
    return model.isDetailOnScreen && model.selectedThreadId == threadId
  }

  /// A push woke the app: catch up through the final feed page, reload the widget and reconcile
  /// notifications, then park the sync before iOS may suspend us. A snapshot or the first partial page
  /// alone is not completion. Overlapping wakes repeat the cycle when necessary, within the existing
  /// three-second queued-resume plus eight-second refresh budget. True when the feed was caught up.
  func backgroundRefresh() async -> Bool {
    await backgroundRefreshes.perform(waitingAtMost: Self.queuedSuspendWait + Self.backgroundWait) {
      await self.backgroundRefreshCycle(waitingAtMost: $0)
    }
  }

  private func backgroundRefreshCycle(waitingAtMost limit: Duration) async -> Bool {
    guard let sync = account?.sync else { return false }
    let deadline = ContinuousClock.now + limit
    let assertion = BackgroundAssertion(name: "Refresh the mirror")
    defer { assertion.end() }
    await controlSync(.resume, waitingAtMost: min(Self.queuedSuspendWait, limit))?.value
    let remaining = min(Self.backgroundWait, ContinuousClock.now.duration(to: deadline))
    let caughtUp = await sync.refresh(waitingAtMost: remaining)
    WidgetCenter.shared.reloadAllTimelines()
    await reconcileNotifications()
    if UIApplication.shared.applicationState != .active {
      await controlSync(.suspend)?.value
    }
    Self.logger.notice("background mirror catch-up completed: \(caughtUp, privacy: .public)")
    return caughtUp
  }

  private enum SyncControl { case suspend, resume }

  /// Queues a suspend or resume behind the ones before it; the returned task ends once it has reached
  /// the loop (for a suspend, once the loop is idle). A suspend holds a background task from now until
  /// then. The account keeps the choice, so a sync it starts meanwhile (a sign-in, a sign-out's
  /// restart) begins parked or running to match.
  ///
  /// With `waitingAtMost`, the call waits for the one before it only that long (a background wake must
  /// finish inside iOS's budget); the earlier call is not cancelled, and a suspend that a later resume
  /// has overtaken this way does nothing when its turn comes, so the last decision still wins.
  @discardableResult private func controlSync(
    _ action: SyncControl, waitingAtMost limit: Duration? = nil
  ) -> Task<Void, Never>? {
    guard let account else { return nil }
    let assertion = action == .suspend ? BackgroundAssertion(name: "Pause the mirror sync") : nil
    if action == .suspend {
      // A deferred backstop must not read the mirror after this suspend has parked the loop and let
      // the app be suspended; the suspend runs it itself, below, under its background task.
      reconcileScheduled?.cancel()
      reconcileScheduled = nil
    }
    let previous = syncControl
    syncControlSerial += 1
    let serial = syncControlSerial
    if action == .resume { lastResumeSerial = serial }
    let task = Task {
      if let previous, let limit {
        if await !Self.wait(for: previous, atMost: limit) {
          Self.logger.notice("a queued pause of the mirror sync is still running; the wake goes ahead")
        }
      } else {
        await previous?.value
      }
      switch action {
      case .suspend:
        if lastResumeSerial < serial {
          await account.suspendSync()
          // Parked, unless a resume overtook it while it waited for the loop.
          if lastResumeSerial < serial {
            syncParked = true
            turnStartsAfter = Date()
          }
        }
        // Before the background task ends: the owed backstop, or the one already running, so the
        // badge and the notifications settle and nothing reads the mirror once the app may sleep. A
        // suspend a later resume has overtaken or is queued behind skips it: the resume (and the wake
        // that sent it) covers that period, and its background task may have expired meanwhile.
        if lastResumeSerial < serial {
          if reconcileOwed {
            await reconcileNotifications()
          } else {
            await notificationWork?.value
          }
        }
      case .resume:
        let at = Date()
        await account.resumeSync()
        if syncParked {
          syncParked = false
          turnStartsAfter = max(turnStartsAfter ?? at, at)
        }
        if reconcileOwed { scheduleReconcile() }
      }
      assertion?.end()
    }
    syncControl = task
    return task
  }

  /// Waits for `task` at most `limit`; true when it finished first. `task` is not cancelled either way.
  private nonisolated static func wait(for task: Task<Void, Never>, atMost limit: Duration) async -> Bool {
    let pending = Mutex<CheckedContinuation<Bool, Never>?>(nil)
    let finish: @Sendable (Bool) -> Void = { finished in
      pending.withLock { continuation in
        defer { continuation = nil }
        return continuation
      }?.resume(returning: finished)
    }
    return await withCheckedContinuation { continuation in
      pending.withLock { $0 = continuation }
      let sleeper = Task {
        try? await Task.sleep(for: limit)
        finish(false)
      }
      Task {
        await task.value
        sleeper.cancel()
        finish(true)
      }
    }
  }

  // MARK: - Delivered notifications and the badge (M8f APNs)

  /// A delivered notification as the backstop reads it.
  private struct Delivered: Sendable {
    var identifier: String
    var key: String?
    var date: Date
  }

  /// A withdrawal push named these keys (`request:<id>`, `turn:<id>`): remove the delivered
  /// notifications that carry one of them. It runs before the wake's background task begins, so it
  /// must never touch the mirror.
  func withdraw(keys: [String]) async {
    let wanted = Set(keys)
    let identifiers = await Self.deliveredNotifications().filter { $0.key.map(wanted.contains) ?? false }
      .map(\.identifier)
    guard !identifiers.isEmpty else { return }
    UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: identifiers)
    Self.logger.notice("withdrew \(identifiers.count, privacy: .public) notifications")
  }

  /// The backstop, at most once a second: a burst of batches (a streaming reply) runs it once at the
  /// end of the interval rather than for each. It never starts while the loop is parked (the app may
  /// be suspended at any moment then); it stays owed for the next resume or suspend.
  private func scheduleReconcile() {
    reconcileOwed = true
    guard reconcileScheduled == nil, !syncParked else { return }
    let elapsed = lastReconcileAt.map { $0.duration(to: .now) } ?? Self.reconcileInterval
    let delay = Self.reconcileInterval - elapsed
    reconcileScheduled = Task {
      if delay > .zero { try? await Task.sleep(for: delay) }
      // Cancelled by a sign-out or a suspend, which has already let go of it.
      guard !Task.isCancelled else { return }
      reconcileScheduled = nil
      guard !syncParked else { return }
      await reconcileNotifications()
    }
  }

  /// The backstop for a withdrawal push that never arrived, then the badge: removes each delivered
  /// notification (old enough to judge, `judgedThrough`) whose request is no longer pending or whose
  /// turn has been read in the mirror, and sets the app icon's badge to the threads that need the owner.
  /// Does nothing while the mirror is unavailable or nobody is signed in.
  func reconcileNotifications() async {
    reconcileOwed = false
    let previous = notificationWork
    let task = Task {
      await previous?.value
      await runReconcile()
    }
    notificationWork = task
    await task.value
  }

  private func runReconcile() async {
    lastReconcileAt = .now
    guard let store, let session = account?.link?.tokenRef else { return }
    let delivered = await Self.deliveredNotifications()
    // Signed out (or in as someone else) meanwhile: what was read belongs to the old session.
    guard account?.link?.tokenRef == session else { return }
    let judged = delivered.filter { $0.date <= judgedThrough }.compactMap { notification in
      notification.key.map { (identifier: notification.identifier, key: $0) }
    }
    let center = UNUserNotificationCenter.current()
    do {
      if !judged.isEmpty {
        let outstanding = try store.stillOutstanding(keys: judged.map(\.key))
        let ended = judged.filter { !outstanding.contains($0.key) }.map(\.identifier)
        if !ended.isEmpty {
          center.removeDeliveredNotifications(withIdentifiers: ended)
          Self.logger.notice("removed \(ended.count, privacy: .public) notifications that have ended")
        }
      }
      let badge = try store.needsYouCount()
      try await center.setBadgeCount(badge)
      if badge != lastBadge {
        lastBadge = badge
        Self.logger.notice("badge \(badge, privacy: .public)")
      }
    } catch {
      Self.logger.error("the notification backstop failed: \(Self.describe(error), privacy: .public)")
    }
  }

  /// Signed out: this app's delivered notifications and its badge belong to the old session.
  private func clearNotifications() {
    reconcileScheduled?.cancel()
    reconcileScheduled = nil
    reconcileOwed = false
    let previous = notificationWork
    notificationWork = Task {
      await previous?.value
      let center = UNUserNotificationCenter.current()
      center.removeAllDeliveredNotifications()
      lastBadge = 0
      do {
        try await center.setBadgeCount(0)
      } catch {
        Self.logger.error("the badge could not be cleared: \(Self.describe(error), privacy: .public)")
      }
    }
  }

  private nonisolated static func deliveredNotifications() async -> [Delivered] {
    await UNUserNotificationCenter.current().deliveredNotifications().map { notification in
      Delivered(
        identifier: notification.request.identifier,
        key: ThreadLink.key(fromNotification: notification.request.content.userInfo), date: notification.date)
    }
  }

  // MARK: - The relay's link (M8c)

  /// The scene's phase changed: active holds the link, background closes it, inactive changes nothing.
  /// Background also pauses the pull loop at an idle point (under a background task, so the app is not
  /// suspended before it gets there), and active lets it go again.
  func enter(_ phase: RelayLifecycle.Phase) {
    control(lifecycle.enter(phase))
    switch phase {
    case .background: controlSync(.suspend)
    case .active: controlSync(.resume)
    case .inactive: break
    }
  }

  /// What a link opened on this phone, or a scanned QR code, may do. Deciding sends nothing.
  func pairLinkDecision(_ url: URL) -> PairLinkDecision {
    Self.flavor.pairLinkDecision(url)
  }

  /// A relay for `link`'s hub, asking the Keychain for the token on every attempt; the read runs on a
  /// thread of its own (D-052), and the token is never kept or logged here.
  private func makeRelay(_ link: MirrorLink) {
    guard let base = try? HubURL.validate(link.hubURL), let ref = SecretRef(rawValue: link.tokenRef) else {
      return
    }
    let relay = MirrorRelay(url: base, token: { [secrets] in try await secrets.read(ref) })
    self.relay = relay
    relayTokenRef = link.tokenRef
    relayRefused = nil
    relayWatch?.cancel()
    relayWatch = Task {
      for await update in relay.updates() {
        switch update {
        case .link(.connected):
          await MirrorHost.shared.relayConnected(relay)
        case .link(.stopped(let reason)):
          MirrorHost.shared.relayStopped(relay, reason: reason)
        default:
          break
        }
      }
    }
  }

  /// A working relay proves the hub is reachable: wake sync's retry too. Only a successful pull
  /// clears its failure banner, and a background sync stays parked until the lifecycle resumes it.
  private func relayConnected(_ connected: MirrorRelay) async {
    guard connected === relay else { return }
    await account?.sync?.nudge()
  }

  /// Stop a relay whose link has ended, after whatever was decided for it before.
  private func retire(_ old: MirrorRelay) {
    relayWatch?.cancel()
    relayWatch = nil
    relay = nil
    relayTokenRef = nil
    relayRefused = nil
    let previous = relayControl
    relayControl = Task {
      await previous?.value
      await old.stop()
    }
  }

  /// The relay stopped itself. A refusal keeps it closed (and says so) until the phone signs in again.
  private func relayStopped(_ stopped: MirrorRelay, reason: String) {
    guard stopped === relay else { return }
    control(lifecycle.linkStopped(reason: reason))
    if lifecycle.refused { relayRefused = Self.relayRefusedMessage }
  }

  private func control(_ action: RelayLifecycle.Action?) {
    // The lifecycle decides only while a relay exists (`hasRelay`), so this guard never drops a decision.
    guard let action, let relay else { return }
    let previous = relayControl
    relayControl = Task {
      await previous?.value
      switch action {
      case .start: await relay.start()
      case .stop: await relay.stop()
      }
    }
  }

  // MARK: - The sync's reports

  /// A local write was made: have the sync loop push it now.
  private func nudge() async {
    await account?.sync?.nudge()
  }

  private func publish(_ batch: AppliedBatch) {
    transport?.publish(batch)
    refreshHostState()
    if !batch.touchedThreadIds.isEmpty || !batch.touchedProjectIds.isEmpty {
      WidgetCenter.shared.reloadAllTimelines()
    }
    scheduleReconcile()
  }

  /// While pulls succeed only the time moves, so nothing is redrawn until a pull fails or recovers.
  private func update(_ status: MirrorSyncStatus) {
    // Each report ends one turn of the loop; the next begins after it. A successful one applied a
    // pull that began after the previous report, so notifications delivered before then can be judged,
    // and the backstop runs (a turn with nothing new publishes no batch).
    let now = Date()
    if status.lastError == nil, let start = turnStartsAfter {
      judgedThrough = max(judgedThrough, start)
      scheduleReconcile()
    }
    turnStartsAfter = now
    // Each cycle may have refreshed the devices list, whether or not the status changed.
    refreshHostState()
    guard status.lastError != nil || syncStatus.lastError != nil, status != syncStatus else { return }
    syncStatus = status
  }

  /// A failure in words for the enrollment sheet. `HubError` is not `LocalizedError`; its description
  /// carries the status, code, and the hub's message.
  static func describe(_ error: any Error) -> String {
    if let error = error as? HubError { return error.description }
    if let error = error as? WorkspaceError { return error.message }
    if let error = error as? KeychainError { return error.description }
    return error.localizedDescription
  }
}

/// A `UIApplication` background task: asks iOS for time to finish before the app is suspended, ended
/// by `end()` or, when that time runs out, by the expiration handler. Ending twice is harmless.
@MainActor final class BackgroundAssertion {
  private var id: UIBackgroundTaskIdentifier = .invalid

  init(name: String) {
    id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
      MainActor.assumeIsolated { self?.end() }
    }
  }

  func end() {
    guard id != .invalid else { return }
    UIApplication.shared.endBackgroundTask(id)
    id = .invalid
  }
}
