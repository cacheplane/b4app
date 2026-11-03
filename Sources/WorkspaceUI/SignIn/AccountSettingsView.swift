import AuthenticationServices
import Foundation
import SwiftUI
import WorkspaceClient
import WorkspaceProtocol

/// The Account page's words (sign-in plan, Task 12; spec "Linking and Settings → Account").
public enum AccountCopy {
  public static let fullName = "Full name"
  /// Under the name: saving it renames a personal org to "<first word>'s Org" (the hub's `set_profile`).
  public static let nameHint = "Your org is named after your first name."
  public static let org = "Org"
  public static let save = "Save"
  public static let methods = "Sign-in methods"
  public static let methodsIntro =
    "Sign in with any of these to reach this account, on this Mac or your iPhone."
  public static let noMethods = "No sign-in methods yet. Add a passkey so you can sign in again."
  public static let addPasskey = "Add a passkey"
  public static let connectApple = "Connect Apple ID"
  public static let remove = "Remove"
  public static let delete = "Delete account…"
  public static let deleteTitle = "Delete account?"
  public static let deleteConfirm = "Delete account"
  public static let cancel = "Cancel"

  public static func deleteMessage(orgName: String, device: String = "Mac") -> String {
    "This deletes your account and everything in \(orgName), at the hub and on this \(device). It can't be undone. Type \(orgName) to confirm."
  }

  public static func removeTitle(_ line: String) -> String { "Remove \(line)?" }
  public static let removeMessage = "You won't be able to sign in with it any more."

  /// The account's only way in can't go (`last_identity`).
  public static let lastIdentity =
    "That's the only way to sign in to this account. Add another one before removing it."
  /// The hub deletes only a personal org's owner (`shared_org`).
  public static let sharedOrg = "This account belongs to a shared org, so it can't be deleted here."
  public static let passkeyRejected = "That passkey wasn't accepted. Try again."
  public static let alreadyApple = "This account already has an Apple ID."
  public static let expired = "That took too long. Try again."
  /// The hub wanted a fresh confirmation it did not get (a grant it refused, or a sign-in method another
  /// device added meanwhile): the methods are read again, and the next try asks.
  public static let stepUpRequired = "Confirm it's you to make this change, then try again."
  /// The hub deleted the account, but the coordinator could not drop its database on this Mac. Nothing
  /// retries that, so the line says only what happened.
  public static let deletedLocalDataKept =
    "Your account was deleted, but its data on this Mac couldn't be removed."

  /// One line for a refused Account page call: never the code or the hub's own text.
  public static func failure(for error: WorkspaceError) -> String {
    switch error.code {
    case .lastIdentity: return lastIdentity
    case .sharedOrg: return sharedOrg
    case .credentialRejected: return passkeyRejected
    case .appleLinked: return alreadyApple
    case .ceremonyExpired: return expired
    case .stepUpRequired: return stepUpRequired
    default: return SignInCopy.accountFailure(for: error)
    }
  }

  /// "Apple ID · added 1 Nov", "Passkey · Brian Love · added 1 Nov": the date in the locale's short
  /// day and month, with the year when it is not this one.
  public static func methodLine(
    _ identity: AccountIdentity, now: Date = Date(), locale: Locale = .current
  )
    -> String
  {
    var parts: [String] = []
    if identity.kind == "apple" {
      parts.append("Apple ID")
    } else {
      parts.append("Passkey")
      let name = identity.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      if !name.isEmpty { parts.append(name) }
    }
    if let date = Timestamp.date(from: identity.createdAt)
      ?? ISO8601DateFormatter().date(from: identity.createdAt)
    {
      parts.append("added \(added(date, now: now, locale: locale))")
    }
    return parts.joined(separator: " · ")
  }

  static func added(_ date: Date, now: Date, locale: Locale) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = locale
    var style = Date.FormatStyle.dateTime.day().month(.abbreviated).locale(locale)
    if calendar.component(.year, from: date) != calendar.component(.year, from: now) {
      style = style.year()
    }
    return date.formatted(style)
  }
}

/// What the Account page shows for the model's state (as `SignInContent` does for the sign-in screen):
/// the view draws exactly this, so the copy and the enabled states can be checked without a window.
struct AccountSettingsContent: Equatable {
  struct Method: Equatable, Identifiable {
    var id: String
    var text: String
    var removeEnabled: Bool
  }

  var fullName: String
  var nameHint = AccountCopy.nameHint
  var orgName: String
  var methods: [Method]
  /// Whether `account.identities` has answered.
  var methodsLoaded: Bool
  var addPasskey = AccountCopy.addPasskey
  /// "Connect Apple ID", when the flavour offers Apple (beta and prod) and the account has none.
  var connectApple: String?
  /// The account the page shows, which Delete account… is bound to.
  var accountId: String?
  var delete = AccountCopy.delete
  var failure: String?

  init(model: WorkspaceModel, now: Date = Date(), locale: Locale = .current) {
    fullName = model.accountStatus?.account?.displayName ?? model.account?.name ?? ""
    orgName = model.accountStatus?.account?.orgName ?? ""
    accountId = model.accountStatus?.account?.id
    let identities = model.identities ?? []
    methodsLoaded = model.identities != nil
    // The last method can't go: the hub refuses it (`last_identity`), so the button says so first.
    methods = identities.map {
      Method(
        id: $0.id, text: AccountCopy.methodLine($0, now: now, locale: locale),
        removeEnabled: identities.count > 1)
    }
    if model.signInConfiguration.appleSignIn, model.identities != nil,
      !identities.contains(where: { $0.kind == "apple" })
    {
      connectApple = AccountCopy.connectApple
    }
    failure = model.accountSettingsFailure
  }
}

// MARK: - The model

extension WorkspaceModel {
  private static func accountCall() -> RequestOptions {
    RequestOptions(operationId: UUID().uuidString.lowercased(), timeout: .seconds(60))
  }

  /// Read the signed-in account's sign-in methods. A transport without accounts leaves them unread.
  public func refreshIdentities() async {
    guard accountSource == .coordinator ? client != nil : hostOwnsAccount, accountState == .signedIn else {
      return
    }
    let generation = accountGeneration
    do {
      let listed = try await accountCalls().identities()
      guard generation == accountGeneration else { return }
      identities = listed
    } catch let error as WorkspaceError
      where error.code == .unsupportedCapability || error.code == .methodUnknown
    {
      return
    } catch {
      guard generation == accountGeneration else { return }
      accountSettingsFailure = AccountCopy.failure(for: WorkspaceError.from(error))
    }
  }

  /// Save an edited full name (1 to 200 characters once trimmed) through `account.completeProfile`.
  /// Unlike onboarding, it never offers "Add your iPhone".
  public func updateFullName(_ name: String) async {
    guard FullName.isValid(name), !accountSettingsBusy else { return }
    accountSettingsBusy = true
    defer { accountSettingsBusy = false }
    accountSettingsFailure = nil
    do {
      let status = try await accountCalls().completeProfile(FullName.trimmed(name))
      applyAccountStatus(status)
      await refreshAccount()
    } catch {
      accountSettingsFailure = AccountCopy.failure(for: WorkspaceError.from(error))
    }
  }

  /// "Add a passkey": confirm it's you (with a passkey, or the Apple ID of an account that has no
  /// passkey yet), then the coordinator begins with that confirmation, the system sheet makes the
  /// passkey, and the attestation goes to the coordinator once. A closed sheet, either one, shows
  /// nothing; a passkey the hub refused is reported unknown to the password manager, as at sign-up.
  /// A passkey the hub kept takes the account's name in the password manager, in place of the hub's
  /// placeholder, as the sign-up passkey does after onboarding (D-105, D-132).
  public func addPasskey(using ceremony: any PasskeyCeremony, apple: any AppleCeremony) async {
    guard !accountSettingsBusy else { return }
    accountSettingsBusy = true
    defer { accountSettingsBusy = false }
    accountSettingsFailure = nil
    let generation = accountGeneration
    do {
      let calls = try accountCalls()
      let stepUp = try await confirmIdentity(passkey: ceremony, apple: apple)
      let begun = try await calls.addPasskeyBegin(stepUp: stepUp)
      let attestation = try await ceremony.register(begun.registration)
      let added: AccountIdentity
      do {
        added = try await calls.addPasskeyFinish(
          AccountAddPasskeyFinish.Params(ceremonyId: begun.ceremonyId, attestation: attestation))
      } catch {
        await reportOrphan(attestation, options: begun.registration, ceremony: ceremony, after: error)
        throw error
      }
      guard generation == accountGeneration else { return }
      add(identity: added)
      await renameAddedPasskey(options: begun.registration, ceremony: ceremony)
    } catch is SignInCanceled {
      return
    } catch is CancellationError {
      return
    } catch is PasskeysNotSetUp {
      accountSettingsFailure = SignInCopy.passkeysNotSetUp
    } catch is PasskeyAlreadyOnDevice {
      // The device refused before making anything: there is no new passkey to report.
      accountSettingsFailure = SignInCopy.passkeyAlreadyOnDevice
    } catch {
      await accountChangeFailed(error, generation: generation)
    }
  }

  /// The name a passkey added in Settings takes: the account's display name, else the profile
  /// button's. The password manager renames by user handle, which all of an account's passkeys
  /// share, so a per-device name is not possible there.
  var addedPasskeyName: String? {
    let names = [accountStatus?.account?.displayName, account?.name]
    return names.lazy.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
      .first { !$0.isEmpty }
  }

  private func renameAddedPasskey(options: JSONValue, ceremony: any PasskeyCeremony) async {
    guard let name = addedPasskeyName,
      let request = try? WebAuthnJSON.registrationRequest(from: options)
    else { return }
    await ceremony.renamePasskey(relyingParty: request.relyingParty, userHandle: request.userID, name: name)
  }

  /// "Connect Apple ID" (beta and prod, while the account has none), after confirming it's you with a
  /// passkey. On the Mac, Apple's web flow through the coordinator, which keeps the verifier
  /// (`account.appleLinkStart` with the confirmation, then the session, then
  /// `account.appleLinkFinish`); on the phone, Apple's native sheet through the host. A closed sheet
  /// shows nothing; `apple_linked` is one line.
  public func connectAppleID(using ceremony: any AppleCeremony, passkey: any PasskeyCeremony) async {
    guard !accountSettingsBusy else { return }
    accountSettingsBusy = true
    defer { accountSettingsBusy = false }
    accountSettingsFailure = nil
    let generation = accountGeneration
    do {
      let linked: AccountIdentity
      let calls = try accountCalls()
      let stepUp = try await confirmIdentity(passkey: passkey, apple: ceremony)
      switch calls {
      case .host(let host):
        let begun = try await host.appleLinkBegin(stepUp: stepUp)
        guard let credential = try await ceremony.nativeSignIn(nonce: begun.nonce) else { return }
        linked = try await host.linkApple(credential, ceremonyId: begun.ceremonyId)
      case .coordinator(let client):
        let start = try await client.request(
          AccountAppleLinkStart.self, AccountStepUpParams(stepUp: stepUp), options: Self.signInCall)
        let handoff = try await Self.webHandoff(
          ceremony, url: start.url, callbackScheme: start.callbackScheme)
        linked = try await client.request(
          AccountAppleLinkFinish.self, AccountAppleLinkFinish.Params(handoff: handoff),
          options: Self.accountCall()
        ).identity
      }
      guard generation == accountGeneration else { return }
      add(identity: linked)
    } catch is SignInCanceled {
      return
    } catch is CancellationError {
      return
    } catch {
      await accountChangeFailed(error, generation: generation)
    }
  }

  /// Confirm it's you before a change that needs it (D-135), and answer the confirmation the change
  /// carries: with a passkey when the account has one, else with its Apple ID (Apple's web flow through
  /// the coordinator on the Mac, the native sheet on the phone). `nil` for an account with no sign-in
  /// method, which has nothing to confirm with and needs none. A closed sheet is `SignInCanceled`.
  func confirmIdentity(passkey: any PasskeyCeremony, apple: any AppleCeremony) async throws -> AccountStepUp?
  {
    if identities == nil { await refreshIdentities() }
    let listed = identities ?? []
    guard !listed.isEmpty else { return nil }
    let calls = try accountCalls()
    if listed.contains(where: { $0.kind == "passkey" }) {
      let begun = try await calls.stepUpBegin()
      let assertion = try await passkey.confirm(begun.authentication)
      return .passkey(ceremonyId: begun.ceremonyId, assertion: assertion)
    }
    switch calls {
    case .host(let host):
      let begun = try await host.stepUpAppleBegin()
      guard let credential = try await apple.nativeSignIn(nonce: begun.nonce) else { throw SignInCanceled() }
      return .appleNative(ceremonyId: begun.ceremonyId, identityToken: credential.identityToken)
    case .coordinator(let client):
      let start = try await client.request(
        AccountStepUpAppleStart.self, EmptyParams(), options: Self.signInCall)
      return .appleWeb(
        handoff: try await Self.webHandoff(apple, url: start.url, callbackScheme: start.callbackScheme))
    }
  }

  /// A refused Settings → Account change, as one line. `step_up_required` means the methods changed
  /// under the page (or the hub refused the confirmation), so they are read again for the next try.
  private func accountChangeFailed(_ error: any Error, generation: Int) async {
    guard generation == accountGeneration else { return }
    let failure = WorkspaceError.from(error)
    accountSettingsFailure = AccountCopy.failure(for: failure)
    if failure.code == .stepUpRequired { await refreshIdentities() }
  }

  /// A method just added, at the end of the list (once).
  private func add(identity: AccountIdentity) {
    var listed = identities ?? []
    listed.removeAll { $0.id == identity.id }
    listed.append(identity)
    identities = listed
  }

  /// "Remove" on one sign-in method, once it is confirmed it's you. The last one is never sent: the
  /// hub would refuse it. A closed sheet removes nothing and shows nothing.
  public func removeIdentity(id: String, passkey: any PasskeyCeremony, apple: any AppleCeremony) async {
    guard let current = identities, current.count > 1, current.contains(where: { $0.id == id }),
      !accountSettingsBusy
    else { return }
    accountSettingsBusy = true
    defer { accountSettingsBusy = false }
    accountSettingsFailure = nil
    let generation = accountGeneration
    do {
      let stepUp = try await confirmIdentity(passkey: passkey, apple: apple)
      let left = try await accountCalls().removeIdentity(id, stepUp: stepUp)
      guard generation == accountGeneration else { return }
      identities = left
    } catch is SignInCanceled {
      return
    } catch is CancellationError {
      return
    } catch {
      guard generation == accountGeneration else { return }
      let failure = WorkspaceError.from(error)
      accountSettingsFailure = AccountCopy.failure(for: failure)
      // Another device changed the methods: show what the hub has now.
      if failure.code == .lastIdentity || failure.code == .stepUpRequired { await refreshIdentities() }
    }
  }

  /// "Delete account…" asks for the org name typed exactly.
  public func canDeleteAccount(typed: String) -> Bool {
    guard let org = accountStatus?.account?.orgName, !org.isEmpty else { return false }
    return typed == org
  }

  /// Delete the account at the hub and its data on this Mac, once the org name is typed exactly, and
  /// only while `accountId` (the account the sheet was opened for) is still the signed-in one: after a
  /// switch to an account whose org has the same name, nothing is sent. It is confirmed it's you first
  /// (a closed sheet sends nothing and shows nothing). A refusal (`shared_org`, `step_up_required`, or
  /// any other) is one line and changes nothing.
  public func deleteAccount(
    typed: String, accountId: String?, passkey: any PasskeyCeremony, apple: any AppleCeremony
  ) async {
    guard let accountId, accountId == accountStatus?.account?.id, canDeleteAccount(typed: typed),
      !deleteInFlight
    else { return }
    deleteInFlight = true
    defer { deleteInFlight = false }
    deleteFailure = nil
    do {
      let stepUp = try await confirmIdentity(passkey: passkey, apple: apple)
      // A switch while the sheet was up: the confirmation is the old account's, so nothing is sent.
      guard accountId == accountStatus?.account?.id else { return }
      let status = try await accountCalls().deleteAccount(stepUp: stepUp)
      applyAccountStatus(status)
    } catch is SignInCanceled {
      return
    } catch is CancellationError {
      return
    } catch {
      let failure = WorkspaceError.from(error)
      if failure.code == .internalError, failure.details?["database"] != nil {
        // Deleted at the hub, and signed out here; only the local drop failed. The Settings window
        // closes with the sign-out, so the sign-in screen says it.
        deleteFailure = AccountCopy.deletedLocalDataKept
        if accountState != .signedIn {
          signInProgress = SignInProgress(failure: AccountCopy.deletedLocalDataKept)
        }
        return
      }
      deleteFailure = AccountCopy.failure(for: failure)
      if failure.code == .stepUpRequired { await refreshIdentities() }
    }
  }
}

// MARK: - The page

/// Settings → Account: the full name (editable), the org, the sign-in methods with Add a passkey,
/// Connect Apple ID (when there is none), and Remove on each (not on the last), then Delete account…
/// at the bottom in the danger style.
struct AccountSettingsView: View {
  @Bindable var model: WorkspaceModel
  @Environment(\.webAuthenticationSession) private var webAuthenticationSession
  @State private var name = ""
  @State private var removing: AccountSettingsContent.Method?
  @State private var deleting = false

  var body: some View {
    let content = AccountSettingsContent(model: model)
    ScrollView {
      VStack(alignment: .leading, spacing: LLA.Space.xl) {
        profile(content)
        LLASectionHead(AccountCopy.methods, intro: AccountCopy.methodsIntro)
        methods(content)
        if let failure = content.failure {
          Text(failure)
            .font(LLAFont.small)
            .foregroundStyle(LLA.Color.danger)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("account.failure")
        }
        Hairline().padding(.top, LLA.Space.s)
        Button(content.delete) {
          model.deleteFailure = nil
          deleting = true
        }
        .buttonStyle(.llaDanger)
        .disabled(model.link != .ready || content.orgName.isEmpty)
        .accessibilityIdentifier("account.delete")
      }
      .padding(LLA.Metrics.margin)
      .frame(maxWidth: 820, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .background(LLA.Color.bg)
    .navigationTitle("Account")
    .task(id: model.accountStatus?.account?.id) {
      name = content.fullName
      await model.refreshIdentities()
    }
    .onChange(of: content.fullName) { _, saved in name = saved }
    .alert(
      AccountCopy.removeTitle(removing?.text ?? ""), isPresented: removeBinding, presenting: removing
    ) { method in
      Button(AccountCopy.remove, role: .destructive) {
        Task {
          await model.removeIdentity(
            id: method.id, passkey: SystemPasskeyCeremony(),
            apple: SystemAppleCeremony(session: webAuthenticationSession))
        }
      }
      Button(AccountCopy.cancel, role: .cancel) {}
    } message: { _ in
      Text(AccountCopy.removeMessage)
    }
    .sheet(isPresented: $deleting) {
      DeleteAccountSheet(model: model, orgName: content.orgName, accountId: content.accountId)
    }
  }

  private var removeBinding: Binding<Bool> {
    Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })
  }

  private func profile(_ content: AccountSettingsContent) -> some View {
    LLACard {
      VStack(alignment: .leading, spacing: LLA.Space.m) {
        Text(AccountCopy.fullName).llaSmallMuted().accessibilityHidden(true)
        HStack(spacing: LLA.Space.s) {
          LLAField(AccountCopy.fullName, text: $name)
            .textContentType(.name)
            .onSubmit(save)
            .accessibilityLabel(AccountCopy.fullName)
            .accessibilityIdentifier("account.name")
          Button(AccountCopy.save, action: save)
            .buttonStyle(.llaSecondary)
            .disabled(!canSave(content))
            .accessibilityIdentifier("account.save")
        }
        Text(content.nameHint)
          .llaSmallMuted()
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("account.nameHint")
        Hairline()
        LLAFacts {
          LLAFact(AccountCopy.org) {
            Text(content.orgName).llaBody().textSelection(.enabled).accessibilityIdentifier("account.org")
          }
        }
      }
    }
  }

  private func canSave(_ content: AccountSettingsContent) -> Bool {
    FullName.isValid(name) && FullName.trimmed(name) != content.fullName && !model.accountSettingsBusy
      && model.link == .ready
  }

  private func save() {
    guard canSave(AccountSettingsContent(model: model)) else { return }
    let name = self.name
    Task { await model.updateFullName(name) }
  }

  private func methods(_ content: AccountSettingsContent) -> some View {
    LLACard {
      VStack(alignment: .leading, spacing: LLA.Space.m) {
        if content.methodsLoaded, content.methods.isEmpty {
          Text(AccountCopy.noMethods).llaMuted().fixedSize(horizontal: false, vertical: true)
        }
        ForEach(Array(content.methods.enumerated()), id: \.element.id) { index, method in
          if index > 0 { Hairline() }
          HStack(spacing: LLA.Space.m) {
            Text(method.text).llaBody().lineLimit(2).accessibilityIdentifier("account.method.\(method.id)")
            Spacer(minLength: LLA.Space.m)
            Button(AccountCopy.remove) { removing = method }
              .buttonStyle(.llaSecondary)
              .disabled(!method.removeEnabled || model.accountSettingsBusy)
              .accessibilityLabel("\(AccountCopy.remove) \(method.text)")
              .accessibilityIdentifier("account.remove.\(method.id)")
          }
        }
        if !content.methods.isEmpty || content.methodsLoaded { Hairline() }
        HStack(spacing: LLA.Space.s) {
          Button(content.addPasskey) {
            Task {
              await model.addPasskey(
                using: SystemPasskeyCeremony(), apple: SystemAppleCeremony(session: webAuthenticationSession))
            }
          }
          .buttonStyle(.llaSecondary)
          .accessibilityIdentifier("account.addPasskey")
          if let apple = content.connectApple {
            Button(apple) {
              Task {
                await model.connectAppleID(
                  using: SystemAppleCeremony(session: webAuthenticationSession),
                  passkey: SystemPasskeyCeremony())
              }
            }
            .buttonStyle(.llaSecondary)
            .accessibilityIdentifier("account.connectApple")
          }
        }
        .disabled(model.accountSettingsBusy || model.link != .ready)
      }
    }
  }
}

/// "Delete account?": the org name typed exactly, then Delete account in the danger style. A refusal
/// shows its one line here and changes nothing.
struct DeleteAccountSheet: View {
  @Bindable var model: WorkspaceModel
  let orgName: String
  /// The account the sheet was opened for; a delete after a switch sends nothing.
  let accountId: String?
  @State private var typed = ""
  @Environment(\.dismiss) private var dismiss
  @Environment(\.webAuthenticationSession) private var webAuthenticationSession

  var body: some View {
    VStack(alignment: .leading, spacing: LLA.Space.l) {
      Text(AccountCopy.deleteTitle).llaTitle().accessibilityAddTraits(.isHeader)
      Text(
        AccountCopy.deleteMessage(orgName: orgName, device: model.accountSource == .host ? "iPhone" : "Mac")
      )
      .llaMuted()
      .fixedSize(horizontal: false, vertical: true)
      LLAField(orgName, text: $typed)
        .onSubmit(delete)
        .accessibilityLabel("Org name")
        .accessibilityIdentifier("account.delete.typed")
      if let failure = model.deleteFailure {
        Text(failure)
          .font(LLAFont.small)
          .foregroundStyle(LLA.Color.danger)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("account.delete.failure")
      }
      HStack(spacing: LLA.Space.s) {
        Spacer()
        Button(AccountCopy.cancel) { dismiss() }
          .buttonStyle(.llaSecondary)
          .keyboardShortcut(.cancelAction)
        Button(AccountCopy.deleteConfirm, action: delete)
          .buttonStyle(.llaDanger)
          .disabled(!model.canDeleteAccount(typed: typed) || model.deleteInFlight)
          .accessibilityIdentifier("account.delete.confirm")
      }
    }
    .padding(LLA.Space.xl)
    #if os(macOS)
      .frame(width: 420)
    #endif
    .background(LLA.Color.bg)
    .tint(LLA.Color.accent)
  }

  private func delete() {
    guard model.canDeleteAccount(typed: typed), !model.deleteInFlight else { return }
    let typed = self.typed
    Task {
      await model.deleteAccount(
        typed: typed, accountId: accountId, passkey: SystemPasskeyCeremony(),
        apple: SystemAppleCeremony(session: webAuthenticationSession))
      // A closed confirmation sheet leaves the account and this sheet as they were.
      if model.deleteFailure == nil, model.accountStatus?.account?.id != accountId { dismiss() }
    }
  }
}
