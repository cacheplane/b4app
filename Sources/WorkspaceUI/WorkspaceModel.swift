import Foundation
import Observation
import WorkspaceClient
import WorkspaceProtocol

public enum LinkState: Sendable, Equatable {
  case connecting, ready, unavailable
}

/// What the sidebar dot says about a thread (spec 3.1: idle, running, waiting, reconnecting, error).
public enum ThreadRowState: String, Sendable, Equatable, CaseIterable {
  case idle, running, waiting, stopping, unknown, reconnecting, error

  public var label: String {
    switch self {
    case .idle: return "Idle"
    case .running: return "Running"
    case .waiting: return "Waiting for you"
    case .stopping: return "Stopping"
    case .unknown: return "Outcome unknown"
    case .reconnecting: return "Runtime offline"
    case .error: return "Connection error"
    }
  }
}

/// A page of the Settings window (the Mac) or sheet (the iPhone).
public enum SettingsPage: String, CaseIterable, Identifiable, Sendable {
  case account, display, connections, servers, remoteAccess, diagnostics

  /// The pages this platform shows. "Account" comes first (sign-in plan, Task 12). "Display" is on both
  /// (Dense changes a thread on the phone too). "Remote access" is the Mac's: it mints the pairing code
  /// and holds itself awake, neither of which the phone does. The phone's Account page reads its host's
  /// account (Task 14).
  nonisolated public static var allCases: [SettingsPage] {
    #if os(macOS)
      [.account, .display, .connections, .servers, .remoteAccess, .diagnostics]
    #else
      [.account, .display, .connections, .servers, .diagnostics]
    #endif
  }

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .account: return "Account"
    case .display: return "Display"
    case .connections: return "Connections"
    case .servers: return "B4 projects"
    case .remoteAccess: return "Remote access"
    case .diagnostics: return "Diagnostics"
    }
  }

  public var systemImage: String {
    switch self {
    case .account: return "person.crop.circle"
    case .display: return "textformat.size"
    case .connections: return "link"
    case .servers: return "server.rack"
    case .remoteAccess: return "iphone"
    case .diagnostics: return "waveform.path.ecg"
    }
  }
}

/// The open thread: cached rows from `thread.read` patched by live events.
public struct ThreadDetail: Sendable, Equatable {
  public var thread: ConversationThread
  public var turns: [Turn]
  public var items: [DisplayItem]
  public var requests: [RuntimeRequest]
  /// Streaming assistant text by native item id, cleared when the item completes.
  public var liveText: [String: String] = [:]

  public var activeTurn: Turn? { turns.last { $0.status != .terminal } }

  mutating func upsert(_ item: DisplayItem) {
    if let index = items.firstIndex(where: { $0.id == item.id }) {
      items[index] = item
    } else {
      items.append(item)
      items.sort { $0.sequence < $1.sequence }
    }
  }

  mutating func upsert(_ turn: Turn) {
    if let index = turns.firstIndex(where: { $0.id == turn.id }) {
      turns[index] = turn
    } else {
      turns.append(turn)
      turns.sort { $0.createdAt < $1.createdAt }
    }
  }
}

/// Renderer-side projection of coordinator state: snapshot first, then live events, resnapshot on
/// desync. Views never talk to the client directly.
@Observable
public final class WorkspaceModel {
  public typealias TransportProvider = @Sendable () async throws -> any WorkspaceTransport

  public private(set) var link: LinkState = .connecting
  public private(set) var linkMessage: String?
  public private(set) var connections: [Connection] = []
  /// Set only by the model itself; open to the module so a test can give a model a large list
  /// without sending it through a transport.
  public internal(set) var threads: [ConversationThread] = [] {
    didSet { holdSelectedState() }
  }
  public private(set) var diagnostics: DiagnosticsReport?
  public private(set) var diagnosticsError: String?
  public private(set) var diagnosticsLoading = false
  public private(set) var servers: [LocalServer] = []
  /// Plan readings (Codex, Claude) and token totals (B4) per connection id, from `usage.read` and
  /// `usage.changed`. Empty on the phone: usage stays on the Mac.
  public internal(set) var usage: [String: ConnectionUsage] = [:]
  /// Checks in progress that have said which try they are on, per connection id.
  public internal(set) var checks: [String: ConnectionCheck] = [:]
  /// When this window last asked for a background check of each connection.
  var lastChecked: [String: Date] = [:]
  /// Latest redacted log tail per server id, replaced on each poll.
  public private(set) var serverLogs: [String: ServerLogs.Result] = [:]
  /// A stop or restart the coordinator refused because a turn is running; the view confirms force.
  public var pendingForceStop: (serverId: String, restart: Bool, threadIds: [String])?
  public private(set) var detail: ThreadDetail?
  public private(set) var detailLoading = false
  public private(set) var busy = false
  /// Every non-terminal turn by thread id, from the snapshot and then from turn events, so the
  /// sidebar shows per-thread state without opening each thread (spec 3.1).
  public private(set) var activeTurns: [String: Turn] = [:]
  public var lastError: String? {
    didSet { if lastError == nil { lastFailure = nil } }
  }
  /// The typed error behind `lastError`, when the failure came from the coordinator.
  public private(set) var lastFailure: WorkspaceError?
  public var composerText = "" {
    didSet {
      if composerText != oldValue, !restoringDraft {
        lastComposerChange = now()
        scheduleDraftSave()
      }
    }
  }
  /// True only while the open thread is actually in front of the owner: the scene is active, the
  /// window is key (Mac), and the detail column is the one showing (iPhone). The views set it. A reply
  /// is marked read only while it is true, and turning true marks the open thread's latest reply read.
  public var isDetailOnScreen = false {
    didSet {
      guard isDetailOnScreen, !oldValue, let id = selectedThreadId else { return }
      acknowledgeOpenThread()
      Task { await markReadIfNeeded(threadId: id) }
    }
  }
  /// Whether the detail column shows: false only while a compact width (the iPhone) shows the list
  /// instead, with the open thread still selected and loaded behind it. The Mac and a regular width
  /// always show it. Unlike `isDetailOnScreen`, it stays true while the Mac's window is not key.
  /// The selected thread's hold lasts only while it is true: going back to the list releases it, and
  /// showing the detail again starts a fresh one from the thread's state now.
  var isDetailColumnShown = true {
    didSet { if isDetailColumnShown != oldValue { holdSelectedState(restart: true) } }
  }
  /// Every environment with its folders, loaded with the threads and refreshed on `environment.changed`.
  public internal(set) var environments: [WorkEnvironment] = []
  /// The account's view settings as stored (one synced row, read with the first snapshot and followed
  /// through `viewSettings.changed`); the defaults until read, and again once the account ends.
  public private(set) var viewSettings = ViewSettings()
  /// Counts every change to `viewSettings` (a set, an event, a read, a sign-out), so a read that was out
  /// meanwhile knows its row is older than what is shown.
  @ObservationIgnored private var viewSettingsChanges = 0
  /// Sets that are out and unanswered. A read that answers meanwhile may carry the row from before
  /// them, so it is not shown; `viewSettingsReadOwed` has it made again once they have settled.
  @ObservationIgnored private var viewSettingsSetsOut = 0
  @ObservationIgnored private var viewSettingsReadOwed = false
  /// The Settings page to show, and a counter the root view watches to open Settings (a window on the
  /// Mac, a sheet on the iPhone); a counter so asking twice opens it twice.
  public var settingsPage: SettingsPage = SettingsPage.allCases[0]
  public var settingsRequest = 0
  /// A notification or widget open waiting for the link or the phone's mirror to catch up.
  /// A later request replaces an earlier one.
  public private(set) var pendingThreadOpen: String?
  @ObservationIgnored private var threadOpenTask: Task<Void, Never>?
  static let threadOpenWait: Duration = .seconds(15)
  /// Counts every `requestOpenThread` and `openNewThread`; the root view moves the iPhone to the
  /// detail column on a change.
  public private(set) var detailRequest = 0
  /// Counts each time the open thread went away (deleted, gone from the list, or the account ended);
  /// the root view moves the iPhone back to the list on a change. A selection cleared for a new thread
  /// asks for nothing.
  public private(set) var sidebarRequest = 0
  /// Counts each request to put the cursor in the new-thread composer; `NewThreadView` focuses its
  /// field on a change, as it does when it appears.
  public internal(set) var newThreadFocusRequest = 0
  /// What the detail column draws; `ThreadsView` draws exactly this, so a command that needs one of the
  /// screens (the folder panel needs the new-thread composer) asks here.
  enum DetailPane: Equatable {
    /// The Mac's environment form (D-212).
    case environment(WorkEnvironment)
    case thread(ConversationThread)
    /// A thread is selected and its row is still being read or opened.
    case opening
    /// Nothing can start a conversation yet.
    case noConnection
    case newThread
  }

  var detailPane: DetailPane {
    #if os(macOS)
      if let id = editingEnvironmentId, let environment = environments.first(where: { $0.id == id }) {
        return .environment(environment)
      }
    #endif
    if let thread = threads.first(where: { $0.id == selectedThreadId }) { return .thread(thread) }
    if selectedThreadId != nil, detailLoading || pendingThreadOpen == selectedThreadId { return .opening }
    return conversationReadyConnections.isEmpty ? .noConnection : .newThread
  }

  var newThreadViewIsShowing: Bool { detailPane == .newThread }
  /// Counts each request for the system folder panel ("Choose folder…"); `NewThreadView` opens it on a
  /// change.
  public internal(set) var chooseFolderRequest = 0
  /// The iPhone's Settings sheet.
  public var showSettingsSheet = false
  /// Set by the Settings views while they are on screen.
  public var settingsVisible = false
  public var selectedThreadId: String? {
    didSet { if selectedThreadId != oldValue { holdSelectedState(restart: true) } }
  }
  /// The most urgent state the selected thread has had since it was selected: the list orders it by
  /// the more urgent of this and its state now, so the thread being read does not move under the owner
  /// (`ListLayout.Selection`; D-208, the owner's changes). Released, and started afresh, whenever the
  /// selection changes, so every way the selection moves (a row, the composer, a delete, sign-out)
  /// moves the hold with it, and whenever the detail column comes or goes (`isDetailColumnShown`: the
  /// iPhone going back to the list); nil while the list shows instead of the detail, and while the
  /// selected thread is not in the live list (unknown yet, or archived). Only the order uses it: the
  /// mark, the badge, and the arrivals keep the real state.
  private(set) var selectionHold: ThreadState?
  /// The palette is up (⌘K and ⇧⌘P on the Mac, the list's search button on the iPhone).
  public var showSearch = false
  /// What the palette opens for, and a counter that moves an open palette to it (`presentPalette`).
  public internal(set) var palettePurpose: PalettePurpose = .find
  public internal(set) var paletteRequest = 0
  /// Counts each request to put the cursor back in the open thread's composer; `ComposerView`
  /// focuses its field on a change.
  public internal(set) var composerFocusRequest = 0
  /// The last `composerFocusRequest` a composer answered. A request made while no composer is on
  /// screen (the palette opened a thread whose view is still loading) is answered by the composer
  /// that appears next.
  @ObservationIgnored var answeredComposerFocusRequest = 0
  /// The profile menu above the sidebar's profile button.
  public var showProfileMenu = false
  public var connectionFilter: String? {
    didSet { if connectionFilter != oldValue { rebaseArrivals() } }
  }
  /// The phone's environment sheet: one environment's name and folders.
  public var environmentSheet: EnvironmentSheetRequest?
  /// The environment the Mac's form shows in the main view (`EnvironmentForm`, D-212), over whatever was
  /// there; nil shows that again. Opening a thread or the new-thread view closes it.
  public internal(set) var editingEnvironmentId: String?
  /// The iPhone's "Other ways to sign in" sheet, over the signed-out screen. On the model, like the
  /// sheets above, so the app holds a pairing link back until it closes.
  public var showSignInOptions = false
  /// Draft writes are debounced; the pending one is flushed by `persistDraftNow()`.
  public private(set) var draftSaveTask: Task<Void, Never>?
  private var restoringDraft = false
  /// Per model, so tests that change it cannot slow each other down (suites run in parallel).
  @ObservationIgnored public var draftSaveDelay: Duration = .milliseconds(600)
  /// A burst of events about one thread becomes one `thread.read` this long after the first. Per model,
  /// like `draftSaveDelay`, so a test that widens it does not change the window for the others.
  @ObservationIgnored public var refetchDelay: Duration = .milliseconds(200)
  /// A draft that changed elsewhere replaces the composer only when it has not been typed in for this long.
  public static var remoteDraftIdle: TimeInterval = 2
  /// The clock for relative times ("Replied 3m ago") and the composer idle rule; tests replace it.
  public var now: @Sendable () -> Date = { Date() }
  /// Each thread opened on this device, with its `lastActivityAt` when it was opened or last seen open
  /// on screen: an approve mark stops pulsing until the thread has new activity. In memory only, never
  /// synced or stored.
  private var acknowledgedActivity: [String: String] = [:]
  /// Which listed threads have just entered the top list, fed on every change to the list
  /// (`noteThreadList`). Observed, so a row redraws when its thread arrives.
  private var arrivals = ArrivalTracker()
  /// Set when the account's rows are forgotten: the next snapshot is a new list, not a change to one,
  /// so it starts the tracker afresh (decision 9: nothing traces when the list is rebuilt after sign-in).
  @ObservationIgnored private var arrivalsAwaitSnapshot = false
  /// This device's small choices (the last model and permission a new thread used); `UserDefaults`
  /// in the apps, which pass it to `init`, and in memory otherwise, so a test never shares the test
  /// runner's defaults with another. Never synced.
  @ObservationIgnored public var preferences: any LocalPreferences
  /// Set after `connection.login`; the view opens it in the system browser and clears it.
  public var pendingLoginURL: URL?

  /// How the coordinator is hosted, in the app's words (M6): a LaunchAgent that needs approval, or
  /// nothing. The app sets these; the UI only shows them. The action runs when its title is shown.
  public var hostNote: String?
  public var hostActionTitle: String?
  public var hostAction: (@MainActor () async -> Void)?
  /// The coordinator version this app was built with; a running coordinator that reports another
  /// version is an upgrade left behind, and `restartCoordinator` (set by the app) replaces it.
  public var expectedCoordinatorVersion: String?
  public var restartCoordinator: (@MainActor () async -> Void)?

  /// The hub user this device is signed in as; nil reads "Not signed in".
  public var account: WorkspaceAccount?
  /// Whether this Mac is joined to a hub, and where its relay link stands, from the last `hub.status`.
  /// The "Remote access" page reads them; the phone has no such status.
  public private(set) var hubJoined = false
  public private(set) var hubLink: HubLinkStatus?
  /// The Mac's "Keep the Mac awake" preference (on until set off), from `settings.read`.
  public private(set) var keepAwake = true
  /// `.host` when the app around the model owns the account (the phone); `refreshAccount()` then
  /// leaves it alone and `logOut()` calls `hostLogOut`.
  public var accountSource: AccountSource = .coordinator
  public var hostLogOut: (@MainActor () async -> Void)?
  /// The host's own account (the phone's `MirrorAccount`, sign-in plan Task 14). With one, a `.host`
  /// model signs in, onboards, logs out, and runs Settings → Account through it, and its root follows
  /// the account as the Mac's does; without one the workspace always shows, as before.
  public var accountHost: (any AccountHost)?

  // MARK: Signing in (sign-in plan, Task 11; the logic is in SignIn/AccountState.swift)

  /// Who is signed in, from `account.status` and then `account.changed`; the root view follows it.
  public internal(set) var accountState: AccountState = .unknown
  /// The last status the coordinator gave, for the org and the display name.
  public internal(set) var accountStatus: AccountStatus.Result?
  /// "The last sign-out could not reach the hub; …", shown until dismissed (`dismissAccountNotice`).
  public internal(set) var accountNotice: String?
  /// The sign-in screen's busy button, failure line, and "Create a new account?" question.
  public internal(set) var signInProgress = SignInProgress()
  /// Onboarding's Continue is out, and the line shown when it failed.
  public internal(set) var onboardingBusy = false
  public internal(set) var onboardingFailure: String?
  /// The flavour's site, Apple flag, and badge; the app sets it (`WorkspaceUI` cannot read `Flavor`).
  public var signInConfiguration: SignInConfiguration = .local
  /// A fresh connection to the coordinator for commands that must not queue behind others on the
  /// main one (`account.logout`). Nil sends them on the main connection.
  @ObservationIgnored public var sideTransportProvider: TransportProvider?
  /// How long a log-out waits for its side connection's hello before it gives up.
  @ObservationIgnored public var sideReadyTimeout: Duration = .seconds(5)
  /// Bumped by `forgetWorkspace()` whenever the signed-in account ends or changes. A read sent under
  /// an older generation belongs to that account: its answer is dropped, not stored.
  @ObservationIgnored var accountGeneration = 0
  /// The registration offered after "No passkey for …", until Create account or Cancel.
  @ObservationIgnored var pendingRegistration: PendingRegistration?
  /// The passkey this device made at sign-up, renamed once onboarding names the account.
  @ObservationIgnored var pendingRename: PendingPasskeyRename?
  // MARK: Account settings and log out (sign-in plan, Task 12; SignIn/AccountSettingsView.swift)

  /// The profile menu's "Log out of <org name>?", while it is asked.
  public internal(set) var logOutConfirmation: LogOutConfirmation?
  /// A log-out is out; the menu's Log out does nothing until it answers.
  public internal(set) var logOutInFlight = false
  /// The one line a refused log-out shows, until dismissed.
  public internal(set) var logOutFailure: String?
  /// The signed-in account's sign-in methods, from `account.identities`; nil until read.
  public internal(set) var identities: [AccountIdentity]?
  /// An Account page call is out (save the name, add or remove a method).
  public internal(set) var accountSettingsBusy = false
  /// The Account page's one failure line.
  public internal(set) var accountSettingsFailure: String?
  /// "Delete account…": the call is out, and the one line a refusal shows.
  public internal(set) var deleteInFlight = false
  public internal(set) var deleteFailure: String?
  /// A change whose passkey or Apple confirmation was closed or could not open: the page offers to
  /// confirm it with an operator's enrollment code instead (D-151). Never holds the code.
  public internal(set) var stepUpCodeOffer: StepUpChange?
  /// "Add your iPhone": set once after a new account finishes onboarding on the Mac, and by the views.
  public var showAddPhone = false
  /// Bumped when the account leaves `.signedIn`, so an open Settings window closes.
  public internal(set) var settingsCloseRequest = 0
  /// The phone's mirror has no joined Mac left: a notice sits above the still browsable list.
  public var hostDisconnected = false
  /// The phone's account has never had a Mac (`GET /v1/devices`, read by the host): "Connect your Mac"
  /// replaces the thread list (sign-in plan, Task 15). The host sets it; false until the list is read.
  public var accountHasNoMac = false

  // MARK: The phone's relay (M8c; the logic is in SendState.swift and HostNotice.swift)

  /// The phone's sends, and the Mac's thread starts, by thread id, one per thread, until settled and
  /// shown.
  public internal(set) var pendingSends: [String: PendingSend] = [:]
  /// A `thread.start` is out, from the Mac or the phone: a second tap starts nothing until its call
  /// returns.
  public internal(set) var isStartingThread = false
  /// The new-thread composer's draft, once made (`newThreadDraft`).
  @ObservationIgnored var newThreadDraftStorage: NewThreadDraft?
  /// The phone's Stop by thread id, and its answers by request id, while they wait or after they failed.
  public internal(set) var stopStates: [String: ControlState] = [:]
  public internal(set) var answerStates: [String: ControlState] = [:]
  /// Each Mac's presence by device id, from `host.presence`; only `MirrorTransport` emits it.
  public internal(set) var hostPresence: [String: HostPresence] = [:]
  /// The phone's own hub link, from `host.presence`; nil until reported (always, on the Mac).
  public internal(set) var hubLinkPhase: HubLinkStatus.State?
  /// Bumped when a phase may have changed with time alone, so views reading `hostPhase` redraw.
  var presenceRevision = 0
  /// The clock the send and presence timers sleep on, read with `now`; tests replace both.
  @ObservationIgnored public var clock: any Clock<Duration> = ContinuousClock()
  /// Counts the phone's link coming up, so a lost send's reply can tell it already came back.
  @ObservationIgnored var linkGeneration = 0
  /// Where the latest snapshot left the event stream.
  @ObservationIgnored private var snapshotPosition: (epoch: String, sequence: Int)?
  @ObservationIgnored var sendTimer: Task<Void, Never>?
  @ObservationIgnored var phaseTimer: Task<Void, Never>?

  /// Whether the profile menu offers Log out.
  public var canLogOut: Bool {
    account != nil && (accountSource == .coordinator || accountHost != nil || hostLogOut != nil)
  }

  public var versionMismatch: String? {
    guard let expected = expectedCoordinatorVersion, let running = diagnostics?.coordinator.version,
      running != expected
    else { return nil }
    return "The running coordinator is \(running); this app is \(expected)."
  }

  private let transportProvider: TransportProvider
  var client: WorkspaceClient?
  private var connectTask: Task<Void, Never>?
  /// Callers of `settledLink()` waiting for the link to leave `.connecting`.
  @ObservationIgnored private var linkWaiters: [CheckedContinuation<LinkState, Never>] = []
  @ObservationIgnored private var lastComposerChange = Date.distantPast
  /// Threads with a `thread.read` already scheduled; further events inside the window join it.
  @ObservationIgnored private var refetchTasks: [String: Task<Void, Never>] = [:]
  /// `"<threadId>/<turnId>"` for every `thread.markRead` sent, so a turn is marked at most once.
  @ObservationIgnored private var markedRead: Set<String> = []
  /// Threads the owner marked unread while open; they stay unread until the thread is opened again
  /// or a new reply finishes.
  @ObservationIgnored private var unreadHold: Set<String> = []
  /// Threads deleted here or elsewhere: nothing about them is shown again, whatever arrives later.
  @ObservationIgnored private var deletedThreadIds: Set<String> = []

  public init(
    transportProvider: @escaping TransportProvider, accountSource: AccountSource = .coordinator,
    preferences: any LocalPreferences = InMemoryPreferences()
  ) {
    self.transportProvider = transportProvider
    self.accountSource = accountSource
    self.preferences = preferences
  }

  /// Unarchived threads under the connection filter: approve, reply, failed, finished, working, and
  /// quiet, pinned first and then newest activity first inside each (`Attention.ordered`).
  public var orderedThreads: [ConversationThread] { Attention.ordered(filtered(archived: false)) }

  /// What the list draws: the threads under the connection filter, arranged by the view settings.
  var listLayout: ListLayout {
    ListLayout.build(
      threads: threads.filter { connectionFilter == nil || $0.connectionId == connectionFilter },
      environments: environments, settings: viewSettings,
      selection: selectedThreadId.map { ListLayout.Selection(threadId: $0, held: selectionHold) })
  }

  /// Keeps `selectionHold` the most urgent state the selected thread has had since it was selected;
  /// `restart` (a new selection, or none) releases the old hold first. Releasing a hold moves rows but
  /// changes no thread's state, so the arrival tracker is not told and nothing traces.
  private func holdSelectedState(restart: Bool = false) {
    var hold = restart ? nil : selectionHold
    if !isDetailColumnShown {
      hold = nil
    } else if let id = selectedThreadId, let thread = threads.first(where: { $0.id == id }) {
      // An archived thread is out of the live list: its hold ends, and starts again if it comes back.
      hold = thread.archived ? nil : min(hold ?? state(of: thread), state(of: thread))
    }
    if hold != selectionHold { selectionHold = hold }
  }

  public func state(of thread: ConversationThread) -> ThreadState { Attention.state(of: thread) }

  private func filtered(archived: Bool) -> [ConversationThread] {
    threads.filter { $0.archived == archived }
      .filter { connectionFilter == nil || $0.connectionId == connectionFilter }
  }

  /// One line under a thread's title saying why it sits where it does. Approve and reply threads name
  /// the request kind when the thread is open (the list's `activity` only counts requests).
  public func reasonLine(for thread: ConversationThread) -> String {
    let state = Attention.state(of: thread)
    switch state {
    case .approve, .reply:
      let pending = detail.flatMap { $0.thread.id == thread.id ? $0.requests : nil }?
        .filter { $0.state == .pending }.min { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
      switch pending?.kind {
      case .commandApproval?, .fileChangeApproval?, .toolPermission?: return "Waiting for your approval"
      case .userQuestion?, .elicitation?: return "Has a question for you"
      case .unknown?, nil: return "Waiting for your input"
      }
    case .failed, .finished:
      let when = relative(thread.activity?.lastActivityAt)
      // Failed, read or not; a finished turn was stopped or replied.
      let word =
        state == .failed ? "Failed" : thread.activity?.latestTurnOutcome == .cancelled ? "Stopped" : "Replied"
      return when.isEmpty ? word : "\(word) \(when)"
    case .working:
      // The phone does not call a turn on an offline Mac working; its state stays as synced.
      return activeTurnLabel(for: thread) ?? "Working"
    case .quiet:
      return thread.activity?.latestTurnId == nil ? "No messages yet" : "Read"
    }
  }

  /// "3 min. ago", or "just now" inside the last minute. The reply's time comes from the Mac's clock,
  /// which can run a little ahead of the phone's, and the formatter then said "in 0 sec.".
  private func relative(_ timestamp: String?) -> String {
    guard let timestamp, let date = Self.date(from: timestamp) else { return "" }
    if now().timeIntervalSince(date) < 60 { return "just now" }
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .short
    return formatter.localizedString(for: date, relativeTo: now())
  }

  private static func date(from timestamp: String) -> Date? {
    if let date = Timestamp.date(from: timestamp) { return date }
    return ISO8601DateFormatter().date(from: timestamp)
  }

  /// Sidebar state for one thread: the connection's availability wins over an idle thread, and a
  /// non-terminal turn wins over both (spec 3.1 indicators).
  public func threadState(_ thread: ConversationThread) -> ThreadRowState {
    if let turn = activeTurns[thread.id] {
      switch turn.status {
      case .submitting, .running: return .running
      case .waitingForUser: return .waiting
      case .stopping: return .stopping
      case .reconciling: return .unknown
      case .terminal: break
      }
    }
    switch connection(id: thread.connectionId)?.status {
    case .offline?, .connecting?: return .reconnecting
    case .error?, .incompatible?: return .error
    default: return .idle
    }
  }

  public func connection(id: String) -> Connection? { connections.first { $0.id == id } }

  /// Connections that can start a thread right now.
  public var conversationReadyConnections: [Connection] {
    connections.filter { $0.enabled && $0.status == .ready }
  }

  public func connect() {
    threadOpenTask?.cancel()
    threadOpenTask = nil
    connectTask?.cancel()
    link = .connecting
    linkMessage = nil
    connectTask = Task { [transportProvider] in
      do {
        // Replaced before it began: the provider is not asked (the phone's host keeps the newest
        // transport it made, which must be the newer connect's).
        if Task.isCancelled { return }
        let transport = try await transportProvider()
        // A connect replaced by a newer one (`reconnect()`) leaves the link to it.
        if Task.isCancelled {
          await transport.close()
          return
        }
        let client = WorkspaceClient(transport: transport)
        self.client = client
        let hello = try await client.ready()
        // Subscribed before the first snapshot, so nothing emitted after it is lost (presence
        // included); the events the snapshot already covers are skipped in `observe`.
        let events = await client.events()
        // Who is signed in comes first: nothing of a store is read, or shown, before it is known.
        try await readAccountState(client)
        if showsStore {
          try await refreshSnapshot()
          await refreshAccount()
        }
        let covered = snapshotPosition ?? (hello.epoch, hello.sequence)
        try Task.checkCancellation()
        link = .ready
        settleLink()
        // Not awaited: a slow `thread.read` must not hold up `observe` (events, desync handling).
        openRequestedThread()
        await observe(client, events: events, covered: covered)
      } catch {
        guard !Task.isCancelled else { return }
        link = .unavailable
        linkMessage = Self.describe(error)
        settleLink()
      }
    }
  }

  /// The link once `connect()` has settled: `.ready` after the first snapshot is in, or `.unavailable`
  /// with `linkMessage` saying why. Returns at once when the link is not `.connecting`.
  public func settledLink() async -> LinkState {
    if link != .connecting { return link }
    return await withCheckedContinuation { linkWaiters.append($0) }
  }

  private func settleLink() {
    let waiters = linkWaiters
    linkWaiters = []
    for waiter in waiters { waiter.resume(returning: link) }
  }

  /// Connect again on a fresh transport, closing the old client once the new connection takes over.
  /// The root does not pass through "unavailable" on the way (the phone, after its account changed).
  func reconnect() {
    let old = client
    client = nil
    connect()
    Task { await old?.close() }
  }

  /// Whether the store is read: someone is signed in, or a host that owns no sign-in shows it always.
  var showsStore: Bool { (accountSource == .host && accountHost == nil) || accountState == .signedIn }

  public func disconnect() async {
    threadOpenTask?.cancel()
    threadOpenTask = nil
    connectTask?.cancel()
    await client?.close()
    client = nil
    endRelayState()
    link = .unavailable
    settleLink()
  }

  /// Open a notification or widget's thread after the link is ready. A new thread may reach the
  /// phone's mirror after its notification, so missing phone reads wait briefly for sync to catch up.
  public func requestOpenThread(_ id: String) {
    detailRequest += 1
    stopThreadOpen()
    lastError = nil
    pendingThreadOpen = id
    openRequestedThread()
  }

  /// Back while a notification's thread is still syncing cancels that open, rather than letting a
  /// late read or timeout change the screen the owner chose.
  public func cancelThreadOpen() {
    guard let id = pendingThreadOpen else { return }
    stopThreadOpen()
    dropSelection(of: id)
  }

  private func stopThreadOpen() {
    threadOpenTask?.cancel()
    threadOpenTask = nil
    pendingThreadOpen = nil
  }

  private func openRequestedThread() {
    guard link == .ready, let id = pendingThreadOpen else { return }
    threadOpenTask?.cancel()
    let clock: any Clock<Duration> = self.clock
    openRequestedThread(id: id, clock: clock)
  }

  private func openRequestedThread<C: Clock<Duration>>(id: String, clock: C) {
    let generation = accountGeneration
    threadOpenTask = Task { [weak self] in
      guard let self else { return }
      if let current = detail, current.thread.id != id { await saveDraft(threadId: current.thread.id) }
      guard !Task.isCancelled, pendingThreadOpen == id, generation == accountGeneration else { return }
      editingEnvironmentId = nil
      selectedThreadId = id
      unreadHold.remove(id)
      let deadline = clock.now.advanced(by: Self.threadOpenWait)
      while !Task.isCancelled, pendingThreadOpen == id, generation == accountGeneration {
        if await loadDetail(id: id) {
          guard !Task.isCancelled, pendingThreadOpen == id, generation == accountGeneration else { return }
          pendingThreadOpen = nil
          threadOpenTask = nil
          await markReadIfNeeded(threadId: id)
          return
        }
        guard !Task.isCancelled, pendingThreadOpen == id, generation == accountGeneration else { return }
        if clock.now >= deadline {
          pendingThreadOpen = nil
          threadOpenTask = nil
          dropSelection(of: id)
          lastError = "This thread is unavailable. Check your connection and try again."
          return
        }
        // Capture an absolute wake-up before suspension: a clock advance between the check and
        // registering a relative sleep must not park this request beyond its original deadline.
        let retryAt = min(deadline, clock.now.advanced(by: .milliseconds(250)))
        do { try await clock.sleep(until: retryAt, tolerance: nil) } catch { return }
      }
    }
  }

  /// Moves the iPhone to the thread column (the root view watches `detailRequest`).
  func showDetailColumn() { detailRequest += 1 }

  /// Open Settings, at `page` when given.
  public func openSettings(_ page: SettingsPage? = nil) {
    if let page { settingsPage = page }
    settingsRequest += 1
  }

  /// Ask the coordinator which hub user it has joined as. A failure keeps the account as it was.
  public func refreshAccount() async {
    guard accountSource == .coordinator, accountState == .signedIn, let client else { return }
    let generation = accountGeneration
    guard let status = try? await client.request(HubStatus.self, EmptyParams()),
      generation == accountGeneration
    else { return }
    account = WorkspaceAccount(status: status, profile: accountStatus?.account)
    hubJoined = status.joined
    hubLink = status.link
    // A status read never clears the notice: only `account.dismissNotice` does.
    if status.notice != nil { accountNotice = SignInCopy.sessionLeftOpen }
  }

  // MARK: - Remote access (the Mac)

  /// A phone can be paired: the coordinator is up and this Mac has joined a hub.
  public var canPair: Bool { link == .ready && hubJoined }

  /// Read the hub status and the preferences the "Remote access" page shows. A failure keeps what the
  /// page showed.
  public func refreshRemoteAccess() async {
    await refreshAccount()
    guard let client else { return }
    if let settings = try? await client.request(SettingsRead.self, EmptyParams()) {
      keepAwake = settings.keepAwake
    }
  }

  /// Turn "Keep the Mac awake" on or off. The value shown follows the coordinator's answer, so a
  /// refusal leaves the old one and sets `lastError`.
  public func setKeepAwake(_ enabled: Bool) async {
    guard
      let settings = await perform({ client in
        try await client.request(
          SettingsUpdate.self, SettingsUpdate.Params(keepAwake: enabled), options: Self.mutation())
      })
    else { return }
    keepAwake = settings.keepAwake
    await refreshAccount()
  }

  /// Mint a pairing code. The code is returned to the caller and kept nowhere here: it lives in the
  /// pairing sheet's state only while the sheet is open (D-058). Sent without an `operationId`, so the
  /// coordinator has nothing to cache. Throws what the coordinator refused with.
  public func pair() async throws -> HubPair.Result {
    guard let client else { throw WorkspaceError(.endpointUnavailable, "Coordinator is not connected.") }
    return try await client.request(HubPair.self, EmptyParams())
  }

  /// Where the latest code stands; nil when the coordinator could not be asked.
  public func pairStatus() async -> HubPairStatus.Result? {
    guard let client else { return nil }
    return try? await client.request(HubPairStatus.self, EmptyParams())
  }

  /// Unlink the phone (through `hostLogOut`), or on the Mac remove this Mac from the account
  /// (`removeThisMac`). The Mac's profile menu logs out with `requestLogOut` instead.
  public func logOut() async {
    if accountSource == .host {
      _ = await logOut(stopWork: false)
      return
    }
    await removeThisMac()
  }

  /// "Remove this Mac from your account" (Remote access): `hub.leave` revokes this Mac's device at the
  /// hub and signs it out. A failure keeps the account and sets `lastError`.
  public func removeThisMac() async {
    // The sign-out that follows forgets the composer; its text is saved first, as at a log-out.
    await persistDraftNow()
    guard
      await perform({ client in
        try await client.request(HubLeave.self, EmptyParams(), options: Self.mutation())
      }) != nil
    else { return }
    await refreshAccount()
  }

  /// Whether the Settings pages can show: someone is signed in (or the host owns the account). When
  /// it turns false an open Settings window closes (`settingsCloseRequest`) and shows a placeholder.
  public var settingsAvailable: Bool {
    (accountSource == .host && accountHost == nil) || accountState == .signedIn
  }

  public func refreshSnapshot() async throws {
    guard let client else { return }
    let generation = accountGeneration
    let snapshot = try await client.request(EventsSnapshot.self, EmptyParams())
    guard generation == accountGeneration else { return }
    connections = snapshot.connections
    // Progress from before the snapshot may never see its closing event.
    checks = [:]
    threads = snapshot.threads
    if arrivalsAwaitSnapshot {
      arrivals.reset()
      arrivalsAwaitSnapshot = false
    }
    noteThreadList()
    // The open thread went while the link was down: nothing stays selected. A start still settling
    // is kept; its thread may not be in the list yet.
    if let id = selectedThreadId, !threads.contains(where: { $0.id == id }), pendingSends[id] == nil,
      pendingThreadOpen != id
    {
      dropSelection(of: id)
    }
    activeTurns = Dictionary(
      snapshot.activeTurns.map { ($0.threadId, $0) }, uniquingKeysWith: { _, new in new })
    resolvePendingSends(with: snapshot.activeTurns)
    if let presence = snapshot.presence { applyPresence(presence) }
    let listed = (try? await client.request(ServerList.self, EmptyParams()).servers) ?? []
    guard generation == accountGeneration else { return }
    servers = listed
    await refreshViewSettings()
    guard generation == accountGeneration else { return }
    await refreshEnvironments()
    guard generation == accountGeneration else { return }
    await client.resetCursor(epoch: snapshot.epoch, sequence: snapshot.sequence)
    snapshotPosition = (snapshot.epoch, snapshot.sequence)
    if let id = selectedThreadId, detail != nil { await loadDetail(id: id) }
    await refreshUsage()
  }

  public func refreshDiagnostics() async {
    guard let client else {
      diagnosticsError = "Coordinator is not connected."
      return
    }
    diagnosticsLoading = true
    defer { diagnosticsLoading = false }
    do {
      diagnostics = try await client.request(
        DiagnosticsRead.self, EmptyParams(), options: RequestOptions(timeout: .seconds(60)))
      diagnosticsError = nil
    } catch {
      diagnosticsError = Self.describe(error)
    }
  }

  // MARK: - Managed servers

  public func server(id: String) -> LocalServer? { servers.first { $0.id == id } }

  /// The route connection on a managed server, when one exists.
  public func connection(serverId: String, route: String) -> Connection? {
    connections.first { $0.localServerId == serverId && $0.routeKey == route }
  }

  private static let serverOperation: Duration = .seconds(150)

  public func addServer(
    projectPath: String, name: String?, mode: LocalServerLaunchMode, envFilePath: String?, port: Int?
  ) async {
    _ = await perform {
      let result = try await $0.request(
        ServerAdd.self,
        ServerAdd.Params(
          projectPath: projectPath, name: name, launchMode: mode, envFilePath: envFilePath, port: port),
        options: Self.mutation(timeout: Self.serverOperation))
      self.merge(result.server)
      return result.server
    }
  }

  public func startServer(id: String) async {
    _ = await perform {
      let result = try await $0.request(
        ServerStart.self, ServerRef(serverId: id), options: Self.mutation(timeout: Self.serverOperation))
      self.merge(result.server)
      return result.server
    }
  }

  public func inspectServer(id: String) async {
    _ = await perform {
      let result = try await $0.request(
        ServerInspect.self, ServerRef(serverId: id), options: Self.mutation(timeout: Self.serverOperation))
      self.merge(result.server)
      return result.server
    }
  }

  public func stopServer(id: String, force: Bool = false) async {
    await lifecycle(ServerStop.self, id: id, force: force, restart: false)
  }

  public func restartServer(id: String, force: Bool = false) async {
    await lifecycle(ServerRestart.self, id: id, force: force, restart: true)
  }

  private func lifecycle<C: WorkspaceCommand>(_ command: C.Type, id: String, force: Bool, restart: Bool) async
  where C.Params == ServerLifecycleParams, C.Result == ServerAdd.Result {
    guard let client else {
      lastError = "Coordinator is not connected."
      return
    }
    busy = true
    defer { busy = false }
    do {
      let result = try await client.request(
        command, ServerLifecycleParams(serverId: id, force: force ? true : nil),
        options: Self.mutation(timeout: Self.serverOperation))
      merge(result.server)
      lastError = nil
    } catch {
      let failure = WorkspaceError.from(error)
      if failure.details?["reason"]?.stringValue == "turn_active" {
        pendingForceStop = (
          id, restart, failure.details?["threadIds"]?.arrayValue?.compactMap(\.stringValue) ?? []
        )
      } else {
        lastError = Self.describe(error)
      }
    }
  }

  public func refreshServerLogs(id: String, lines: Int = 200) async {
    guard let client else { return }
    let previous = serverLogs[id]
    guard
      let result = try? await client.request(
        ServerLogs.self, ServerLogs.Params(serverId: id, lines: lines, afterOffset: previous?.offset))
    else { return }
    if var previous, result.offset >= previous.offset, !result.truncated {
      previous.lines = Array((previous.lines + result.lines).suffix(lines))
      previous.offset = result.offset
      serverLogs[id] = previous
    } else {
      serverLogs[id] = result
    }
  }

  public func connectRoute(serverId: String, route: String) async {
    await addConnection(kind: .b4, route: route, serverId: serverId)
  }

  private func merge(_ server: LocalServer) {
    if let index = servers.firstIndex(where: { $0.id == server.id }) {
      servers[index] = server
    } else {
      servers.append(server)
    }
  }

  // MARK: - Connections

  @discardableResult
  public func addConnection(
    kind: ConnectionKind, label: String? = nil, executablePath: String? = nil, url: String? = nil,
    route: String? = nil, authReference: String? = nil, serverId: String? = nil
  ) async
    -> Connection?
  {
    await perform {
      let result = try await $0.request(
        ConnectionAdd.self,
        ConnectionAdd.Params(
          kind: kind, label: label, executablePath: executablePath, url: url, route: route,
          authReference: authReference, serverId: serverId),
        options: Self.mutation(timeout: .seconds(60)))
      self.merge(result.connection)
      if result.connection.status != .ready, let message = result.inspection.message {
        self.lastError = message
      }
      return result.connection
    }
  }

  public func inspectConnection(id: String) async {
    _ = await perform {
      let result = try await $0.request(
        ConnectionInspect.self, ConnectionInspect.Params(connectionId: id),
        options: Self.mutation(timeout: .seconds(60)))
      self.merge(result.connection)
      return result.connection
    }
  }

  public func login(connectionId: String) async {
    _ = await perform {
      let result = try await $0.request(
        ConnectionLogin.self, ConnectionLogin.Params(connectionId: connectionId), options: Self.mutation())
      self.pendingLoginURL = URL(string: result.authUrl)
      return result
    }
  }

  // MARK: - Threads

  public func createThread(connectionId: String, directory: String?, title: String?) async {
    let created: ConversationThread? = await perform {
      try await $0.request(
        ThreadCreate.self,
        ThreadCreate.Params(connectionId: connectionId, workingDirectory: directory, title: title),
        options: Self.mutation(timeout: .seconds(60))
      ).thread
    }
    if let created {
      threads.removeAll { $0.id == created.id }
      threads.insert(created, at: 0)
      noteThreadList()
      await openThread(id: created.id)
    }
  }

  /// The empty pane is the new-thread composer: keep the open thread's unsent text, select nothing,
  /// start in `environmentId` when given, and put the cursor in the composer's field.
  /// The pane changes first; the text is saved after, so the phone does not wait on the relay to move.
  public func openNewThread(environmentId: String? = nil) async {
    await openNewThread { draft in if let environmentId { draft.selectEnvironment(environmentId) } }
  }

  /// From a "By environment" heading: the composer starts in the group's environment, or with no folder
  /// under "No folder".
  func openNewThread(in group: ListLayout.Group) async {
    await openNewThread { draft in
      if let id = group.environmentId { draft.selectEnvironment(id) } else { draft.selectNoFolder() }
    }
  }

  private func openNewThread(preselect: (NewThreadDraft) -> Void) async {
    stopThreadOpen()
    editingEnvironmentId = nil
    let open = detail.map { (threadId: $0.thread.id, text: composerText) }
    selectedThreadId = nil
    preselect(newThreadDraft)
    newThreadFocusRequest += 1
    detailRequest += 1
    if let open { await saveDraft(threadId: open.threadId, text: open.text) }
  }

  public func openThread(id: String) async {
    stopThreadOpen()
    editingEnvironmentId = nil
    if let current = detail, current.thread.id != id { await saveDraft(threadId: current.thread.id) }
    selectedThreadId = id
    unreadHold.remove(id)
    await loadDetail(id: id)
    if let at = threads.first(where: { $0.id == id })?.activity?.lastActivityAt {
      acknowledgedActivity[id] = at
    }
    await markReadIfNeeded(threadId: id)
  }

  /// Whether the thread was opened on this device since its latest activity. The open thread counts
  /// while its detail is in front of the owner, so a request arriving on it does not pulse; a selected
  /// thread behind the phone's list or in an inactive window still does.
  public func isAcknowledged(_ thread: ConversationThread) -> Bool {
    if isDetailOnScreen, selectedThreadId == thread.id { return true }
    guard let at = thread.activity?.lastActivityAt else { return false }
    return acknowledgedActivity[thread.id] == at
  }

  /// While the open thread is on screen, records its current activity as seen, so it stays
  /// acknowledged after the owner moves on. Called on every change to the list and when the detail
  /// comes on screen.
  private func acknowledgeOpenThread() {
    guard isDetailOnScreen, let id = selectedThreadId,
      let at = threads.first(where: { $0.id == id })?.activity?.lastActivityAt
    else { return }
    acknowledgedActivity[id] = at
  }

  /// The thread's arrival in the top list while it lasts: its row slides in and its edge is traced.
  public func arrival(for thread: ConversationThread) -> Arrival? {
    arrivals.arrival(for: thread.id, at: now())
  }

  /// Feeds the tracker the states of the list as it now shows (`orderedThreads`, under the filters).
  /// Stowed threads (Collapsed, Hidden) are in it: one that starts needing the owner arrives in the top
  /// list, and one that only moves between the stowed set and the lower list changes no state.
  /// Called once per change to `threads`. `asBaseline` records the list without tracing anything: the
  /// owner's own action (Mark as Unread, a mark-read rollback, unarchiving) or a change to which
  /// threads the filter shows is not an arrival, and another thread's live trace goes on.
  private func noteThreadList(asBaseline: Bool = false) {
    acknowledgeOpenThread()
    let states = Dictionary(
      orderedThreads.map { ($0.id, state(of: $0)) }, uniquingKeysWith: { first, _ in first })
    if asBaseline {
      arrivals.record(states, at: now())
    } else {
      _ = arrivals.update(states, at: now())
    }
  }

  /// A filter change shows another list, not a changed one: the tracker starts afresh from it, so
  /// nothing traces now and a thread that changes under the new filter still does.
  private func rebaseArrivals() {
    arrivals.reset()
    noteThreadList()
  }

  @discardableResult private func loadDetail(id: String) async -> Bool {
    guard let client else { return true }
    detailLoading = true
    defer { detailLoading = false }
    let generation = accountGeneration
    do {
      let read = try await client.request(
        ThreadRead.self, ThreadRead.Params(threadId: id), options: RequestOptions(timeout: .seconds(60)))
      guard !Task.isCancelled, generation == accountGeneration, selectedThreadId == id else { return true }
      // Deleted while this read was out (a refresh can start just before a delete): stay closed.
      if deletedThreadIds.contains(id) { return true }
      // The saved draft is restored only when switching threads, and before the detail is published
      // so the composer is live only once it is settled. A refresh of the open thread (snapshot,
      // wake, a connection change) keeps whatever is being typed: restoring from disk there would
      // overwrite it, and the save already scheduled would then persist the overwrite.
      if detail?.thread.id != id {
        let draft = try? await client.request(DraftRead.self, DraftRead.Params(threadId: id)).draft
        guard !Task.isCancelled, generation == accountGeneration, selectedThreadId == id else { return true }
        restoringDraft = true
        composerText = draft?.text ?? ""
        restoringDraft = false
      }
      var next = ThreadDetail(
        thread: read.thread, turns: read.turns, items: read.items, requests: read.requests)
      // A reload of the open thread mid-reply keeps the text streamed so far: the next delta appends
      // to it, and only a completion or the turn's end clears it, as without the reload.
      if let current = detail, current.thread.id == id, next.activeTurn != nil {
        next.liveText = current.liveText
      }
      detail = next
      store(read.thread)
      resolvePendingSends(with: read.turns)
      prunePendingSends()
      if let active = read.turns.last(where: { $0.status != .terminal }) {
        activeTurns[id] = active
      } else {
        activeTurns[id] = nil
      }
      lastError = nil
    } catch {
      guard !Task.isCancelled, generation == accountGeneration, selectedThreadId == id else { return true }
      if startedThreadMissing(threadId: id, error: error) || deletedThreadIds.contains(id) { return true }
      // A push can precede the phone's first pull of a new thread. Only external phone opens wait;
      // an ordinary read (or a Mac read) keeps its existing not-found behavior.
      if relaysThroughHub, pendingThreadOpen == id, WorkspaceError.from(error).code == .notFound {
        return false
      }
      // Gone (a notification or widget row for a thread deleted since): nothing stays selected.
      if WorkspaceError.from(error).code == .notFound { dropSelection(of: id) }
      lastError = Self.describe(error)
    }
    return true
  }

  public func saveDraft(threadId: String) async {
    await saveDraft(threadId: threadId, text: composerText)
  }

  func saveDraft(threadId: String, text: String) async {
    guard let client else { return }
    _ = try? await client.request(
      DraftSave.self, DraftSave.Params(threadId: threadId, text: text), options: Self.mutation())
  }

  /// Save the open thread's draft shortly after typing stops, so a crash or Quit keeps the text.
  private func scheduleDraftSave() {
    draftSaveTask?.cancel()
    guard let threadId = detail?.thread.id else { return }
    let delay = draftSaveDelay
    draftSaveTask = Task { [weak self] in
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled, let self, self.detail?.thread.id == threadId else { return }
      await self.saveDraft(threadId: threadId)
      self.draftSaveTask = nil
    }
  }

  /// Drop the debounced draft write; the caller saves the text itself.
  func cancelPendingDraftSave() {
    draftSaveTask?.cancel()
    draftSaveTask = nil
  }

  /// Flush the pending draft write now (app termination, window close).
  public func persistDraftNow() async {
    draftSaveTask?.cancel()
    draftSaveTask = nil
    guard let threadId = detail?.thread.id else { return }
    await saveDraft(threadId: threadId)
  }

  /// Deliberate reconciliation of one thread: unresolved turn, native history, continuity.
  public func reconcileThread(id: String) async {
    let read: ThreadRead.Result? = await perform {
      try await $0.request(
        ThreadReconcile.self, ThreadReconcile.Params(threadId: id),
        options: Self.mutation(timeout: .seconds(60)))
    }
    guard let read else { return }
    threads.removeAll { $0.id == read.thread.id }
    threads.insert(read.thread, at: 0)
    noteThreadList()
    if detail?.thread.id == id {
      detail = ThreadDetail(
        thread: read.thread, turns: read.turns, items: read.items, requests: read.requests)
    }
    activeTurns[id] = read.turns.last { $0.status != .terminal }
  }

  public func updateThread(id: String, title: String? = nil, pinned: Bool? = nil, archived: Bool? = nil) async
  {
    _ = await perform {
      try await $0.request(
        ThreadUpdate.self,
        ThreadUpdate.Params(threadId: id, title: title, pinned: pinned, archived: archived),
        options: Self.mutation()
      ).thread
    }
  }

  // MARK: - View settings

  public func setArrangement(_ arrangement: ViewSettings.Arrangement) async {
    await setViewSetting(\.arrangement, arrangement, ViewSettingsSet.Params(arrangement: arrangement))
  }

  public func setQuietThreads(_ quietThreads: ViewSettings.QuietThreads) async {
    await setViewSetting(\.quietThreads, quietThreads, ViewSettingsSet.Params(quietThreads: quietThreads))
  }

  public func setShowArchived(_ showArchived: Bool) async {
    await setViewSetting(\.showArchived, showArchived, ViewSettingsSet.Params(showArchived: showArchived))
  }

  public func setDensity(_ density: ViewSettings.Density) async {
    await setViewSetting(\.density, density, ViewSettingsSet.Params(density: density))
  }

  /// Whether the Mac's sidebar draws the threads that do not need the owner as tight rows: Dense, on the
  /// Mac. The phone (which relays through the hub) keeps its 44 pt rows at either density.
  var tightQuietRows: Bool { viewSettings.density == .dense && !relaysThroughHub }

  /// Dense draws a thread as message, line, answer. Both platforms.
  var denseThread: Bool { viewSettings.density == .dense }

  /// Dense draws the composer with one line in place of its row of pickers. The Mac only: the phone and
  /// the iPad keep their pickers at either density.
  var denseComposer: Bool {
    #if os(macOS)
      viewSettings.density == .dense
    #else
      false
    #endif
  }

  /// One setting, written optimistically (decision 12): shown at once, then sent with only that field.
  /// The answer's row may predate a later set or a change from elsewhere, so only this field is taken
  /// from it, and only while the field still shows this write's value; the other fields are left to
  /// their own writes and to the events. A refusal puts the old value back on the same terms and says
  /// why on the sidebar's error line.
  private func setViewSetting<Value: Equatable>(
    _ field: WritableKeyPath<ViewSettings, Value>, _ value: Value, _ params: ViewSettingsSet.Params
  ) async {
    let generation = accountGeneration
    let old = viewSettings[keyPath: field]
    var shown = viewSettings
    shown[keyPath: field] = value
    showViewSettings(shown)
    viewSettingsSetsOut += 1
    let stored = await perform {
      try await $0.request(ViewSettingsSet.self, params, options: Self.mutation())
    }
    // The account ended meanwhile: its counters were reset with it, and this answer is nobody's.
    guard generation == accountGeneration else { return }
    viewSettingsSetsOut -= 1
    if viewSettings[keyPath: field] == value {
      var settled = viewSettings
      settled[keyPath: field] = stored?[keyPath: field] ?? old
      showViewSettings(settled)
    }
    // A read answered while this was out and was held back: make it now.
    if viewSettingsSetsOut == 0, viewSettingsReadOwed {
      viewSettingsReadOwed = false
      await refreshViewSettings()
    }
  }

  /// Read the account's view settings, with each snapshot (connect, reconnect, sign-in, desync). A read
  /// that fails keeps what is shown (the defaults, on a first connect) and never holds the list back.
  /// A read that a set or an event overtook is not shown, since its row is older than what they
  /// showed; it is made again (a few times at most), so the fields they did not touch still load. A read
  /// that answers while a set is out waits for the set and is made again then.
  /// After the last try an overtaken read is given up: the next snapshot reads again.
  func refreshViewSettings() async {
    let generation = accountGeneration
    for _ in 0..<Self.viewSettingsReadTries {
      let changes = viewSettingsChanges
      guard let client, let settings = try? await client.request(ViewSettingsGet.self, EmptyParams()),
        generation == accountGeneration
      else { return }
      if viewSettingsSetsOut > 0 {
        viewSettingsReadOwed = true
        return
      }
      if changes == viewSettingsChanges {
        showViewSettings(settings)
        return
      }
    }
  }

  private static let viewSettingsReadTries = 3

  /// A new arrangement, or archived threads shown or hidden, is another list rather than a changed one:
  /// the arrival tracker starts afresh from it, as on a filter change.
  private func showViewSettings(_ settings: ViewSettings) {
    viewSettingsChanges += 1
    let old = viewSettings
    guard settings != old else { return }
    viewSettings = settings
    if settings.arrangement != old.arrangement || settings.showArchived != old.showArchived {
      rebaseArrivals()
    }
  }

  // MARK: - Environments

  public func refreshEnvironments() async {
    let generation = accountGeneration
    guard let client, let list = try? await client.request(EnvironmentList.self, EmptyParams()),
      generation == accountGeneration
    else { return }
    environments = list.environments
    // The form's environment went (deleted here or from the phone, or emptied by a move): show what was there.
    if let editing = editingEnvironmentId, !environments.contains(where: { $0.id == editing }) {
      editingEnvironmentId = nil
    }
    // A thread whose environment went is now under "No folder": regrouped, not arrived.
    noteThreadList(asBaseline: true)
  }

  /// Open the Mac's environment form in the main view; Done (`closeEnvironmentForm`) shows what was there.
  public func openEnvironmentForm(id: String) {
    editingEnvironmentId = id
  }

  public func closeEnvironmentForm() {
    editingEnvironmentId = nil
  }

  /// Save an edit of `environment`, the Mac's form or the phone's sheet. A name alone is a rename (on the
  /// phone written to the mirror at once and queued for the hub, so it works with the Mac offline); a
  /// folder change goes to the Mac with the name in one update, which the Mac validates. The failure is
  /// the caller's to show, never `lastError`.
  func editEnvironment(
    _ environment: WorkEnvironment, name: String, addFolders: [String] = [], removeFolders: [String] = []
  ) async -> Result<WorkEnvironment, WorkspaceError> {
    if addFolders.isEmpty, removeFolders.isEmpty {
      guard name != environment.name else { return .success(environment) }
      return await environmentEdit(.environmentRename) {
        try await $0.request(
          EnvironmentRename.self, EnvironmentRename.Params(environmentId: environment.id, name: name),
          options: $1
        ).environment
      }
    }
    return await environmentEdit(.environmentUpdate) {
      try await $0.request(
        EnvironmentUpdate.self,
        EnvironmentUpdate.Params(
          environmentId: environment.id, name: name == environment.name ? nil : name,
          addFolders: addFolders.isEmpty ? nil : addFolders,
          removeFolders: removeFolders.isEmpty ? nil : removeFolders),
        options: $1
      ).environment
    }
  }

  /// Delete an environment on its Mac (from the phone, through the hub): its threads move to "No folder".
  /// Nil when it went; otherwise why not, for the caller to show.
  @discardableResult
  func deleteEnvironment(id: String) async -> WorkspaceError? {
    guard let client else { return WorkspaceError(.endpointUnavailable, "Coordinator is not connected.") }
    do {
      _ = try await client.request(
        EnvironmentDelete.self, EnvironmentDelete.Params(environmentId: id),
        options: Self.mutation(timeout: Self.relayTimeout(for: .environmentDelete)))
    } catch {
      return WorkspaceError.from(error)
    }
    environments.removeAll { $0.id == id }
    if editingEnvironmentId == id { editingEnvironmentId = nil }
    return nil
  }

  /// One environment command whose failure the caller shows itself; the environment it returns joins the
  /// list until the synced rows (or `environment.changed`) replace it.
  private func environmentEdit(
    _ method: WorkspaceProtocol.Method,
    _ body: (WorkspaceClient, RequestOptions) async throws -> WorkEnvironment
  ) async -> Result<WorkEnvironment, WorkspaceError> {
    guard let client else {
      return .failure(WorkspaceError(.endpointUnavailable, "Coordinator is not connected."))
    }
    do {
      let environment = try await body(client, Self.mutation(timeout: Self.relayTimeout(for: method)))
      merge(environment)
      return .success(environment)
    } catch {
      return .failure(WorkspaceError.from(error))
    }
  }

  func merge(_ environment: WorkEnvironment) {
    if let index = environments.firstIndex(where: { $0.id == environment.id }) {
      environments[index] = environment
    } else {
      environments.append(environment)
    }
  }

  // MARK: - Read state

  /// Mark the thread unread again (spec: context menu on the Mac, swipe on the phone).
  public func markUnread(id: String) async {
    let previous = threads.first { $0.id == id }?.readTurnId
    unreadHold.insert(id)
    markedRead = markedRead.filter { !$0.hasPrefix("\(id)/") }
    setReadTurn(threadId: id, turnId: nil, ownAction: true)
    let result: ConversationThread? = await perform {
      try await $0.request(
        ThreadMarkRead.self, ThreadMarkRead.Params(threadId: id, turnId: nil), options: Self.mutation()
      ).thread
    }
    if let result {
      store(result)
    } else {
      unreadHold.remove(id)
      setReadTurn(threadId: id, turnId: previous, ownAction: true)
    }
  }

  /// When the open thread's latest turn is finished and is not the one marked read, mark it read:
  /// once per (thread, turn) for the life of the model. Nothing is sent for a turn still running, and
  /// nothing while the thread is not on screen (spec "Read state": the reply must be seen); the
  /// detail stays loaded behind the iPhone's list and the Mac's inactive window, so loaded is not seen.
  private func markReadIfNeeded(threadId: String) async {
    guard isDetailOnScreen, selectedThreadId == threadId else { return }
    guard let detail, detail.thread.id == threadId, !unreadHold.contains(threadId) else { return }
    guard let latest = detail.turns.max(by: { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }),
      latest.status == .terminal
    else { return }
    let readTurnId = threads.first { $0.id == threadId }?.readTurnId ?? detail.thread.readTurnId
    guard readTurnId != latest.id, markedRead.insert("\(threadId)/\(latest.id)").inserted else { return }
    guard let client else {
      markedRead.remove("\(threadId)/\(latest.id)")
      return
    }
    setReadTurn(threadId: threadId, turnId: latest.id)
    do {
      let result = try await client.request(
        ThreadMarkRead.self, ThreadMarkRead.Params(threadId: threadId, turnId: latest.id),
        options: Self.mutation())
      store(result.thread)
    } catch {
      // Not sent after all: the dot comes back and a later open may try again.
      markedRead.remove("\(threadId)/\(latest.id)")
      if threads.first(where: { $0.id == threadId })?.readTurnId == latest.id {
        setReadTurn(threadId: threadId, turnId: readTurnId, ownAction: true)
      }
    }
  }

  /// Set the read marker on the list row and the open detail at once, so the row's state changes
  /// before the coordinator has answered. `ownAction` (Mark as Unread and the rollbacks) moves the row
  /// without tracing it.
  private func setReadTurn(threadId: String, turnId: String?, ownAction: Bool = false) {
    if let index = threads.firstIndex(where: { $0.id == threadId }) {
      threads[index].readTurnId = turnId
      noteThreadList(asBaseline: ownAction)
    }
    if detail?.thread.id == threadId { detail?.thread.readTurnId = turnId }
  }

  /// Put a fresher copy of a thread into the list (and the open detail), keeping the `activity` and
  /// owner name an event payload may lack.
  func store(_ thread: ConversationThread) {
    if thread.userDeletedAt != nil || deletedThreadIds.contains(thread.id) {
      return forget(threadId: thread.id)
    }
    var fresh = thread
    // Archiving or unarchiving moves a thread into or out of a list; it does not arrive.
    var moved = false
    if let index = threads.firstIndex(where: { $0.id == thread.id }) {
      fresh.activity = fresh.activity ?? threads[index].activity
      fresh.ownerDeviceName = fresh.ownerDeviceName ?? threads[index].ownerDeviceName
      fresh.ownerDeviceId = fresh.ownerDeviceId ?? threads[index].ownerDeviceId
      moved = threads[index].archived != fresh.archived
      threads[index] = fresh
    } else {
      threads.append(fresh)
    }
    noteThreadList(asBaseline: moved)
    if detail?.thread.id == thread.id { detail?.thread = fresh }
  }

  /// Drop a deleted thread everywhere: the list, its running turn and send state, and the open detail,
  /// whose unsent text is discarded rather than saved or sent.
  func forget(threadId: String) {
    if pendingThreadOpen == threadId { stopThreadOpen() }
    deletedThreadIds.insert(threadId)
    threads.removeAll { $0.id == threadId }
    noteThreadList()
    activeTurns[threadId] = nil
    stopStates[threadId] = nil
    pendingSends[threadId] = nil
    refetchTasks.removeValue(forKey: threadId)?.cancel()
    unreadHold.remove(threadId)
    if detail?.thread.id == threadId {
      draftSaveTask?.cancel()
      draftSaveTask = nil
      detail = nil
      restoringDraft = true
      composerText = ""
      restoringDraft = false
    }
    dropSelection(of: threadId)
  }

  /// The selected thread is gone: select nothing, and send the iPhone back to the list.
  private func dropSelection(of threadId: String) {
    guard selectedThreadId == threadId else { return }
    selectedThreadId = nil
    sidebarRequest += 1
  }

  // MARK: - Keeping rows current

  /// Re-read one thread shortly after an event about it, so its `activity` (and the open thread's
  /// turns and requests) are current. The first event opens a window; the rest join its one read.
  private func scheduleRefetch(threadId: String) {
    guard refetchTasks[threadId] == nil else { return }
    let delay = refetchDelay
    refetchTasks[threadId] = Task { [weak self] in
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled, let self else { return }
      self.refetchTasks[threadId] = nil
      await self.refetch(threadId: threadId)
    }
  }

  private func refetch(threadId: String) async {
    let generation = accountGeneration
    guard let client,
      let read = try? await client.request(
        ThreadRead.self, ThreadRead.Params(threadId: threadId), options: RequestOptions(timeout: .seconds(60))
      ),
      generation == accountGeneration
    else { return }
    if var current = detail, current.thread.id == threadId {
      current.turns = read.turns
      current.items = read.items
      current.requests = read.requests
      detail = current
      activeTurns[threadId] = read.turns.last { $0.status != .terminal }
      prunePendingSends()
    }
    resolvePendingSends(with: read.turns)
    store(read.thread)
    await markReadIfNeeded(threadId: threadId)
  }

  /// A draft changed on another device shows in the open composer, but only when nothing has been
  /// typed for `remoteDraftIdle` seconds: a focused composer keeps what is being typed.
  private func reloadRemoteDraftIfIdle(threadId: String) {
    guard now().timeIntervalSince(lastComposerChange) >= Self.remoteDraftIdle, let client else { return }
    let stamp = lastComposerChange
    Task {
      guard
        let draft = try? await client.request(DraftRead.self, DraftRead.Params(threadId: threadId)).draft,
        detail?.thread.id == threadId, lastComposerChange == stamp, composerText != draft.text
      else { return }
      restoringDraft = true
      composerText = draft.text
      restoringDraft = false
    }
  }

  // MARK: - Turns and requests

  public func send() async {
    guard let detail else { return }
    // The phone: through the hub, with the send's state kept until the Mac's answer (SendState.swift).
    if relaysThroughHub {
      await relaySend(threadId: detail.thread.id)
      return
    }
    let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    let generation = accountGeneration
    composerText = ""
    let sent: Turn? = await perform {
      try await $0.request(
        TurnSend.self, TurnSend.Params(threadId: detail.thread.id, text: text),
        options: Self.mutation(timeout: .seconds(90))
      ).turn
    }
    // A refusal can already have a terminal turn (for example, a stopped B4 endpoint). Keep the
    // input for deliberate recovery even when no active turn remains; never overwrite newer text.
    if sent == nil, generation == accountGeneration,
      selectedThreadId == detail.thread.id, self.detail?.thread.id == detail.thread.id,
      !deletedThreadIds.contains(detail.thread.id), composerText.isEmpty
    {
      composerText = text
    }
  }

  public func stop() async {
    guard let detail else { return }
    if relaysThroughHub {
      await relayStop(threadId: detail.thread.id)
      return
    }
    _ = await perform {
      try await $0.request(
        TurnInterrupt.self, TurnInterrupt.Params(threadId: detail.thread.id), options: Self.mutation()
      ).turn
    }
  }

  // MARK: - Lifecycle (spec 10.3)

  /// What the coordinator is running now, for the Quit choice. Nil when the coordinator is unreachable.
  public func activeWork(timeout: Duration = .seconds(10)) async -> WorkspaceActiveWork.Result? {
    guard let client else { return nil }
    return try? await client.request(
      WorkspaceActiveWork.self, EmptyParams(), options: RequestOptions(timeout: timeout))
  }

  /// Stop owned local work (local turns, owned servers); remote runs are detached, not cancelled.
  public func stopLocalWork() async -> WorkspaceStopLocalWork.Result? {
    await perform {
      try await $0.request(
        WorkspaceStopLocalWork.self, EmptyParams(), options: Self.mutation(timeout: .seconds(90)))
    }
  }

  /// After the Mac wakes or the link comes back: fresh snapshot, then ask every runtime about every
  /// unresolved turn. Nothing is re-sent.
  public func reconcileAfter(_ reason: String) async {
    guard showsStore else { return }
    try? await refreshSnapshot()
    guard let client else { return }
    _ = try? await client.request(
      WorkspaceReconcile.self, WorkspaceReconcile.Params(reason: reason),
      options: Self.mutation(timeout: .seconds(120)))
    if let id = selectedThreadId, detail != nil { await loadDetail(id: id) }
  }

  /// The next action for the last failure, in the context of the open thread's connection.
  public var remediation: Remediation? {
    guard let failure = lastFailure else { return nil }
    let connection = detail.flatMap { self.connection(id: $0.thread.connectionId) }
    return Remediation.for(failure, connection: connection)
  }

  /// Carry out a remediation's action. Each one is an ordinary command the user could issue by hand.
  public func perform(_ action: Remediation.Action) async {
    switch action {
    case .none: break
    case .signIn(let connectionId): await login(connectionId: connectionId)
    case .openConnections: openSettings(.connections)
    case .openServers: openSettings(.servers)
    case .newThread: await openNewThread(environmentId: detail?.thread.environmentId)
    case .checkAgain:
      if let id = detail?.thread.id { await reconcileThread(id: id) }
      // Reconciliation clears the notice on success and supplies the current failure otherwise.
      return
    case .abandonTurn: if let id = detail?.thread.id { await abandonTurn(threadId: id) }
    }
    if case .none = action { return }
    lastError = nil
  }

  /// Deliberate recovery for an outcome-unknown turn (spec 10.1.4). Nothing is re-sent.
  public func abandonTurn(threadId: String) async {
    _ = await perform {
      try await $0.request(
        TurnAbandon.self, TurnInterrupt.Params(threadId: threadId), options: Self.mutation()
      )
      .turn
    }
  }

  public func respond(requestId: String, decision: RuntimeDecision) async {
    if relaysThroughHub {
      await relayRespond(RequestRespond.Params(requestId: requestId, decision: decision))
      return
    }
    _ = await perform {
      try await $0.request(
        RequestRespond.self, RequestRespond.Params(requestId: requestId, decision: decision),
        options: Self.mutation()
      ).request
    }
  }

  public func answer(requestId: String, answers: [String: [String]]) async {
    if relaysThroughHub {
      await relayRespond(RequestRespond.Params(requestId: requestId, answers: answers))
      return
    }
    _ = await perform {
      try await $0.request(
        RequestRespond.self, RequestRespond.Params(requestId: requestId, answers: answers),
        options: Self.mutation()
      ).request
    }
  }

  // MARK: - Internals

  static func mutation(timeout: Duration = .seconds(30)) -> RequestOptions {
    RequestOptions(operationId: UUID().uuidString.lowercased(), timeout: timeout)
  }

  func perform<T: Sendable>(_ body: (WorkspaceClient) async throws -> T) async -> T? {
    guard let client else {
      lastError = "Coordinator is not connected."
      return nil
    }
    busy = true
    defer { busy = false }
    do {
      let value = try await body(client)
      lastError = nil
      return value
    } catch {
      lastFailure = WorkspaceError.from(error)
      lastError = Self.describe(error)
      return nil
    }
  }

  func merge(_ connection: Connection) {
    if let index = connections.firstIndex(where: { $0.id == connection.id }) {
      connections[index] = connection
    } else {
      connections.append(connection)
    }
  }

  /// `covered` is the first snapshot's position: events at or before it are already in the snapshot
  /// (presence too, which the phone's snapshot carries).
  private func observe(
    _ client: WorkspaceClient, events: AsyncStream<EventEnvelope>, covered: (epoch: String, sequence: Int)
  ) async {
    let desync = await client.desync()
    let desyncTask = Task { @MainActor in
      for await _ in desync { await self.reconcileAfter("reconnect") }
    }
    for await envelope in events {
      if envelope.epoch == covered.epoch, envelope.sequence <= covered.sequence { continue }
      apply(envelope.event)
    }
    desyncTask.cancel()
    // A client replaced by `reconnect()` or `disconnect()` says nothing about the link now.
    if link == .ready, self.client === client {
      link = .unavailable
      linkMessage = "Coordinator connection closed."
    }
  }

  func apply(_ event: AdapterEvent) {
    if let threadId = event.threadId, deletedThreadIds.contains(threadId) { return }
    switch event.kind {
    case .threadUpdated:
      if let thread = try? event.payload["thread"]?.decode(ConversationThread.self) {
        store(thread)
        if detail?.thread.id == thread.id { reloadRemoteDraftIfIdle(threadId: thread.id) }
        scheduleRefetch(threadId: thread.id)
      }
    case .environmentChanged:
      Task { await refreshEnvironments() }
    case .viewSettingsChanged:
      if let settings = try? event.payload["settings"]?.decode(ViewSettings.self) {
        showViewSettings(settings)
      }
    case .serverChanged:
      if let server = try? event.payload["server"]?.decode(LocalServer.self) { merge(server) }
    case .usageChanged:
      applyUsage(event)
    case .connectionChanged:
      noteCheck(event)
      // A change made elsewhere (a rename, a new key) carries the whole connection.
      if let connection = try? event.payload["connection"]?.decode(Connection.self) { merge(connection) }
      // A connection this client has not seen (added by the CLI or another window): refetch.
      if !connections.contains(where: { $0.id == event.connectionId }) {
        Task { try? await refreshSnapshot() }
      }
      if let index = connections.firstIndex(where: { $0.id == event.connectionId }) {
        if let status = event.payload["status"]?.stringValue.flatMap(ConnectionStatus.init(rawValue:)) {
          connections[index].status = status
        }
        if let auth = event.payload["authStatus"]?.stringValue.flatMap(AuthStatus.init(rawValue:)) {
          connections[index].authStatus = auth
        }
      }
    case .hostPresence:
      applyPresence(event)
    case .accountChanged:
      if accountSource == .coordinator, let status = try? event.payload.decode(AccountStatus.Result.self) {
        applyAccountStatus(status)
      }
    case .turnAcknowledged, .turnStateChanged, .turnFinished:
      if let threadId = event.threadId, let turn = try? event.payload["turn"]?.decode(Turn.self) {
        activeTurns[threadId] = turn.status == .terminal ? nil : turn
        if turn.status == .terminal { stopStates[threadId] = nil }
        resolvePendingSends(with: [turn])
      }
      applyToDetail(event)
      if let threadId = event.threadId {
        scheduleRefetch(threadId: threadId)
        if event.kind == .turnFinished, connections.first(where: { $0.id == event.connectionId })?.kind == .b4
        {
          Task { await refreshUsage() }
        }
        if event.kind == .turnFinished, detail?.thread.id == threadId {
          unreadHold.remove(threadId)
          Task { await markReadIfNeeded(threadId: threadId) }
        }
      }
    case .runtimeRequestOpened, .runtimeRequestResolved, .runtimeRequestExpired:
      applyToDetail(event)
      if let threadId = event.threadId { scheduleRefetch(threadId: threadId) }
    default:
      applyToDetail(event)
    }
  }

  private func applyToDetail(_ event: AdapterEvent) {
    guard var current = detail, event.threadId == current.thread.id else { return }
    switch event.kind {
    case .messageDelta:
      if let itemId = event.nativeIds["itemId"], let delta = event.payload["delta"]?.stringValue {
        current.liveText[itemId, default: ""] += delta
      }
    case .messageStarted, .messageCompleted, .toolStarted, .toolCompleted:
      if let item = try? event.payload["displayItem"]?.decode(DisplayItem.self) {
        current.upsert(item)
        if event.kind == .messageCompleted || event.kind == .toolCompleted, let nativeId = item.nativeItemId {
          current.liveText[nativeId] = nil
        }
      }
    case .turnAcknowledged, .turnStateChanged, .turnFinished:
      if let turn = try? event.payload["turn"]?.decode(Turn.self) { current.upsert(turn) }
      if event.kind == .turnFinished { current.liveText = [:] }
    case .runtimeRequestOpened:
      if let request = try? event.payload["runtimeRequest"]?.decode(RuntimeRequest.self),
        request.state == .pending, !current.requests.contains(where: { $0.id == request.id })
      {
        current.requests.append(request)
      }
    case .runtimeRequestResolved, .runtimeRequestExpired:
      if let request = try? event.payload["runtimeRequest"]?.decode(RuntimeRequest.self) {
        current.requests.removeAll { $0.id == request.id }
      } else if let nativeId = event.nativeIds["requestId"] {
        current.requests.removeAll {
          $0.nativeRequestId == nativeId && $0.adapterGeneration == event.adapterGeneration
        }
      }
    case .adapterError:
      lastError = event.payload["message"]?.stringValue
    default:
      break
    }
    detail = current
    prunePendingSends()
  }

  /// Everything of an account that is no longer the signed-in one: no row, filter, pending send (they
  /// hold message text), or timer of it may stay, or write into the next account's store.
  func forgetWorkspace() {
    stopThreadOpen()
    accountGeneration += 1
    draftSaveTask?.cancel()
    draftSaveTask = nil
    for task in refetchTasks.values { task.cancel() }
    refetchTasks = [:]
    markedRead = []
    unreadHold = []
    endRelayState()
    isStartingThread = false
    forgetNewThreadDraft()
    connectionFilter = nil
    showViewSettings(ViewSettings())
    viewSettingsSetsOut = 0
    viewSettingsReadOwed = false
    pendingForceStop = nil
    diagnosticsError = nil
    connections = []
    threads = []
    environments = []
    servers = []
    serverLogs = [:]
    activeTurns = [:]
    detail = nil
    selectedThreadId = nil
    sidebarRequest += 1
    // An open request of the account that left must not move the next sign-in to an empty thread
    // column (the root view acts on `detailRequest` when it mounts) or open a thread of the old one.
    detailRequest = 0
    pendingThreadOpen = nil
    // With no thread open, clearing the composer schedules no draft save.
    composerText = ""
    account = nil
    hubJoined = false
    hubLink = nil
    diagnostics = nil
    environmentSheet = nil
    editingEnvironmentId = nil
    showSearch = false
    showProfileMenu = false
    lastError = nil
    showAddPhone = false
    logOutConfirmation = nil
    logOutFailure = nil
    identities = nil
    accountSettingsFailure = nil
    deleteFailure = nil
    stepUpCodeOffer = nil
    pendingRename = nil
    // Last, after the filters' resets above: the next account's first snapshot traces nothing.
    arrivals.reset()
    arrivalsAwaitSnapshot = true
  }

  static func describe(_ error: any Error) -> String {
    let failure = WorkspaceError.from(error)
    return "\(failure.message) [\(failure.code.rawValue)]"
  }
}
