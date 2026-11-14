try:
    import os
    import sys
    import time
    START = BOOTSTRAP_START
    PARENT_END = BOOTSTRAP_PARENT_END
    import hashlib
    import json
    import math
    from pathlib import Path
    import re
    import selectors
    import signal
    import stat
    import subprocess
    import tempfile
    CANCELLED = False
    OWNERS = []
    FAILURE_CLEANUP_USED = False
    MAX_INPUT = 4194304
    MAX_SAMPLE = 262144
    MAX_OUTPUT = 65536
    SOURCE_PINS = {'Sources/Coordinator/Accounts/AccountManager.swift': '06119d341433560101eca806f4497eb4ae93b9b99c06db2968ce33e8520d2cfe', 'Sources/Coordinator/HubSync/HubOwnerCarrier.swift': '217eee004c3d36fbeffc4a7efb96bc9eee955ca656eacc0e000dcb619332f51b', 'Sources/Coordinator/HubSync/HubSync.swift': '1e5524a1fb3616c6ce2db218168b3c4d144ba57821c51b5c06dbdbcdc2b7338c', 'Sources/WorkspaceStorage/ProtocolActivation.swift': '1d0ec09f0c7e7a176761d75a597af1767d727e66490744d9947521a15d34ff2c', 'Tests/CoordinatorTests/HubOwnerCarrierTests.swift': '23a1c01b827d4d0ee1c533ba5c0391500efd37c28d0fa71182eecb43c70af23f'}
    SOURCE_NAMES = ['AccountCommandTests.swift', 'AccountManagerTests.swift', 'AgentProtocolAccountMigrationL2Tests.swift', 'AgentProtocolAccountMigrationTests.swift', 'AgentProtocolArchiveATests.swift', 'AgentProtocolConnectionIdentityTests.swift', 'AgentProtocolFoundationFixture.swift', 'AgentProtocolGrantCredentialTests.swift', 'AgentProtocolIdentityManagedFixtures.swift', 'AgentProtocolLegacyManagedTests.swift', 'AgentProtocolMainTenAccountReopenTests.swift', 'AgentProtocolMigrationBackupPathTests.swift', 'AgentProtocolPrivateBackupTests.swift', 'AgentProtocolResourceFixture.swift', 'AgentProtocolRetirementTests.swift', 'AgentProtocolUnicodeIdentityTests.swift', 'CoordinatorTests.swift', 'EnvironmentServiceTests.swift', 'FakeB4Project.swift', 'HubLinkRelayTests.swift', 'HubOwnerCarrierTests.swift', 'HubPullTests.swift', 'HubSyncTests.swift', 'InspectionObservation.swift', 'InspectionObservationTests.swift', 'InspectionRequestObservation.swift', 'InspectionRequestObservationTests.swift', 'KeepAwakeTests.swift', 'LaunchAgentInstallTests.swift', 'LauncherTests.swift', 'LegacyAdoptionLiveTests.swift', 'LegacyAdoptionTests.swift', 'LocalServerTests.swift', 'OwnedCloseConcurrencyTests.swift', 'PairingTests.swift', 'RelayExecutorTests.swift', 'SessionTests.swift', 'SignedInCoordinator.swift', 'SleepWatcherTests.swift', 'SocketClosePreservationTests.swift', 'SocketLifecycleTests.swift', 'SocketResponseOwnershipTests.swift', 'SocketServerShutdownTests.swift', 'SyncSignal.swift', 'ThreadDeleteTests.swift', 'UsageTests.swift']
    ARGUMENT_TEMPLATE = ['-target', 'arm64-apple-macosx26.0', '-incremental', '-enable-batch-mode', '-serialize-diagnostics', '-index-store-path', '{CHECKOUT}/.build/arm64-apple-macosx/debug/index/store', '-Onone', '-enable-testing', '-Xfrontend', '-enable-cross-import-overlays', '-j3', '-DSWIFT_PACKAGE', '-DDEBUG', '-DSWIFT_MODULE_RESOURCE_BUNDLE_UNAVAILABLE', '-Xcc', '-fmodule-map-file={CHECKOUT}/.build/arm64-apple-macosx/debug/CNIOLLHTTP.build/module.modulemap', '-Xcc', '-I', '-Xcc', '{CHECKOUT}/.build/checkouts/swift-nio/Sources/CNIOLLHTTP/include', '-Xcc', '-fmodule-map-file={CHECKOUT}/.build/arm64-apple-macosx/debug/CNIOAtomics.build/module.modulemap', '-Xcc', '-I', '-Xcc', '{CHECKOUT}/.build/checkouts/swift-nio/Sources/CNIOAtomics/include', '-Xcc', '-fmodule-map-file={CHECKOUT}/.build/checkouts/swift-atomics/Sources/_AtomicsShims/include/module.modulemap', '-Xcc', '-I', '-Xcc', '{CHECKOUT}/.build/checkouts/swift-atomics/Sources/_AtomicsShims/include', '-Xcc', '-fmodule-map-file={CHECKOUT}/.build/arm64-apple-macosx/debug/CNIOWASI.build/module.modulemap', '-Xcc', '-I', '-Xcc', '{CHECKOUT}/.build/checkouts/swift-nio/Sources/CNIOWASI/include', '-Xcc', '-fmodule-map-file={CHECKOUT}/.build/checkouts/swift-nio/Sources/CNIOWindows/include/module.modulemap', '-Xcc', '-I', '-Xcc', '{CHECKOUT}/.build/checkouts/swift-nio/Sources/CNIOWindows/include', '-Xcc', '-fmodule-map-file={CHECKOUT}/.build/arm64-apple-macosx/debug/CNIOLinux.build/module.modulemap', '-Xcc', '-I', '-Xcc', '{CHECKOUT}/.build/checkouts/swift-nio/Sources/CNIOLinux/include', '-Xcc', '-fmodule-map-file={CHECKOUT}/.build/arm64-apple-macosx/debug/CNIODarwin.build/module.modulemap', '-Xcc', '-I', '-Xcc', '{CHECKOUT}/.build/checkouts/swift-nio/Sources/CNIODarwin/include', '-Xcc', '-fmodule-map-file={CHECKOUT}/.build/arm64-apple-macosx/debug/CNIOFreeBSD.build/module.modulemap', '-Xcc', '-I', '-Xcc', '{CHECKOUT}/.build/checkouts/swift-nio/Sources/CNIOFreeBSD/include', '-Xcc', '-fmodule-map-file={CHECKOUT}/.build/arm64-apple-macosx/debug/CNIOOpenBSD.build/module.modulemap', '-Xcc', '-I', '-Xcc', '{CHECKOUT}/.build/checkouts/swift-nio/Sources/CNIOOpenBSD/include', '-Xcc', '-fmodule-map-file={CHECKOUT}/.build/arm64-apple-macosx/debug/CNIOPosix.build/module.modulemap', '-Xcc', '-I', '-Xcc', '{CHECKOUT}/.build/checkouts/swift-nio/Sources/CNIOPosix/include', '-Xcc', '-fmodule-map-file={CHECKOUT}/.build/checkouts/swift-subprocess/Sources/_SubprocessCShims/include/module.modulemap', '-Xcc', '-I', '-Xcc', '{CHECKOUT}/.build/checkouts/swift-subprocess/Sources/_SubprocessCShims/include', '-module-cache-path', '{CHECKOUT}/.build/arm64-apple-macosx/debug/ModuleCache', '-parseable-output', '-parse-as-library', '-swift-version', '6', '-enable-upcoming-feature', 'NonisolatedNonsendingByDefault', '-enable-upcoming-feature', 'InferIsolatedConformances', '-plugin-path', '/Applications/Xcode_26.6.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing', '-sdk', '/Applications/Xcode_26.6.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk', '-F', '/Applications/Xcode_26.6.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks', '-I', '/Applications/Xcode_26.6.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib', '-L', '/Applications/Xcode_26.6.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib', '-g', '-Xcc', '-isysroot', '-Xcc', '/Applications/Xcode_26.6.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk', '-Xcc', '-F', '-Xcc', '/Applications/Xcode_26.6.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks', '-Xcc', '-fPIC', '-Xcc', '-g', '-package-name', 'b4app']
    TOP_FIELDS = {'builtTestProducts': 'array', 'copyCommands': 'object', 'explicitTargetDependencyImportCheckingMode': 'object', 'generatedSourceTargetSet': 'array', 'pluginDescriptions': 'array', 'swiftCommands': 'object', 'swiftFrontendCommands': 'object', 'swiftTargetScanArgs': 'object', 'targetDependencyMap': 'object', 'testDiscoveryCommands': 'object', 'testEntryPointCommands': 'object', 'traitConfiguration': 'object', 'writeCommands': 'object'}
    FIELD_TYPES = {'executable': 'string', 'fileList': 'string', 'importPath': 'string', 'inputs': 'array', 'isLibrary': 'boolean', 'moduleName': 'string', 'moduleOutputPath': 'string', 'objects': 'array', 'otherArguments': 'array', 'outputFileMapPath': 'string', 'outputs': 'array', 'prepareForIndexing': 'boolean', 'sources': 'array', 'tempsPath': 'string', 'wholeModuleOptimization': 'boolean'}
    ORIGIN_FIXTURES = [('Positive.swift', 'import Foundation\n@testable import Coordinator\ntypealias Origin = HubSync.ConfiguredClientOrigin\nfunc readIdentity(_ original: Origin) -> UUID { original.identity }\n', '0c951a76d897a2bc9512ccd34b37e12cad203d81f63c29b692b9d1de4a2c4e36'), ('PrivateInit.swift', 'import Foundation\n@testable import Coordinator\nlet forbidden = HubSync.ConfiguredClientOrigin.init(hub:database:baseURL:reference:store:makeAPI:)\n', '19552054a41d62dc904c2c4631687c61c2d4524d4758e884156bfa95f2cd8da6'), ('ImmutableIdentity.swift', 'import Foundation\n@testable import Coordinator\nfunc mutate(_ original: HubSync.ConfiguredClientOrigin) {\n  original.identity = UUID()\n}\n', '2236ff3f57371ef42ed1c9e1fc4b9ce0ad8e50195bf170d3b3de13c031fdbd8f')]
    RECEIPT_SOURCE_PINS = {'Sources/WorkspaceStorage/ProtocolActivation.swift': '1d0ec09f0c7e7a176761d75a597af1767d727e66490744d9947521a15d34ff2c', 'Sources/WorkspaceStorage/WorkspaceDatabase.swift': '4aa79857d10a9709150318c7aea4b948476f31a55ffbd0452af89ee2635e74c8', 'Sources/WorkspaceStorage/PostgresClient.swift': 'd713d50ed4183abb642f4ca6689d773c8b25306ac225ea0dd9936e0704cfc803', 'Tests/WorkspaceStorageTests/OwnedProtocolProofWriteTests.swift': '4c75114692e36b2d7f88a2c3da0c29647007df8aff89190de561a4fe45790ad6'}
    RECEIPT_FIXTURES = [('ReceiptPositive.swift', 'import Foundation\n@testable import WorkspaceStorage\nfunc readReceipt(_ original: ProtocolOwnedProofWriteReceipt) -> Bool {\n  original.disposition == .committedCurrent\n}\n', 'd4e6ed95cb6e848538d7d3bf06d5ea11696c39682cb1139a335bf88efe57a6ec'), ('ReceiptPrivateInit.swift', 'import Foundation\n@testable import WorkspaceStorage\nlet forbidden = ProtocolOwnedProofWriteReceipt.init(payload:)\n', '1dcf49dae19150643bb72c35272a70e236aa240cdb82b3baa915ce70bddee104'), ('ReceiptImmutable.swift', 'import Foundation\n@testable import WorkspaceStorage\nfunc mutate(_ original: inout ProtocolOwnedProofWriteReceipt) {\n  original.disposition = .committedCurrent\n}\n', '62eab97c64f20a5d70e8c13f6527d2856ea281afa0f2e3c3f704dcb1f572bd53')]
    if len(sys.argv) != 2 or sys.argv[0] != "-" or sys.argv[1] not in ("origin", "receipt"):
        raise ValueError()
    BUNDLE = sys.argv[1]
    FIXTURES = ORIGIN_FIXTURES if BUNDLE == "origin" else RECEIPT_FIXTURES
    MODULE_NAME = "HubOwnerOriginSealProbe" if BUNDLE == "origin" else "OwnedProofReceiptSealProbe"
    DEVELOPER = "/Applications/Xcode_26.6.app/Contents/Developer"
    TOOLCHAIN = DEVELOPER + "/Toolchains/XcodeDefault.xctoolchain"
    COMPILER = TOOLCHAIN + "/usr/bin/swiftc"
    PLATFORM = DEVELOPER + "/Platforms/MacOSX.platform/Developer"
    SDK = PLATFORM + "/SDKs/MacOSX26.5.sdk"

    class Failure(Exception):
        def __init__(self, code):
            self.code = code

    def require(condition, code):
        if not condition:
            raise Failure(code)

    def emit(category, **fields):
        print(json.dumps({"category": category, "bundle": BUNDLE, **fields}, sort_keys=True), flush=True)

    def cancelled(_number, _frame):
        global CANCELLED
        CANCELLED = True

    def safe_string(value):
        require(isinstance(value, str) and len(value) <= MAX_SAMPLE, "string_shape")
        require(not any(ord(c) < 32 or 127 <= ord(c) <= 159 for c in value), "string_control")
        require(re.search(r"(?:bearer\s|secret:|secretref:|secret-reference:)", value, re.IGNORECASE) is None,
                "sensitive_literal")
        return value

    def contained(path, anchor):
        require(path != anchor and path.is_relative_to(anchor), "path_containment")
        return path

    def read_regular(path, anchor, cap):
        resolved = contained(path.resolve(strict=True), anchor)
        fd = os.open(resolved, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd, "rb") as stream:
            before = os.fstat(stream.fileno())
            require(stat.S_ISREG(before.st_mode) and 0 <= before.st_size <= cap, "file_shape")
            data = stream.read(cap + 1)
            after = os.fstat(stream.fileno())
            require(len(data) <= cap and len(data) == before.st_size, "file_size")
            require((before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns)
                    == (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns),
                    "file_changed")
        return resolved, data

    def unique_object(pairs):
        result = {}
        for key, value in pairs:
            require(key not in result, "duplicate_key")
            result[key] = value
        return result

    def finite_float(text):
        value = float(text)
        require(math.isfinite(value), "nonfinite_number")
        return value

    def reject_constant(_text):
        raise Failure("nonfinite_number")

    def decode_json(data):
        try:
            return json.loads(data.decode("utf-8"), object_pairs_hook=unique_object,
                              parse_float=finite_float, parse_constant=reject_constant)
        except (ValueError, UnicodeError, RecursionError):
            raise Failure("json_invalid") from None

    def json_type(value):
        if value is None:
            return "null"
        if isinstance(value, bool):
            return "boolean"
        if isinstance(value, dict):
            return "object"
        if isinstance(value, list):
            return "array"
        if isinstance(value, str):
            return "string"
        if isinstance(value, int):
            return "integer"
        if isinstance(value, float):
            return "number"
        raise Failure("json_shape")

    def field_types(value):
        require(isinstance(value, dict) and len(value) <= 256, "field_shape")
        return {safe_string(key): json_type(child) for key, child in value.items()}

    def checked_tree(value):
        pending = [(value, 0)]
        count = 0
        while pending:
            item, depth = pending.pop()
            count += 1
            require(count <= 16384 and depth <= 64, "tree_bound")
            if isinstance(item, dict):
                require(len(item) <= 16384 - count, "tree_bound")
                for key, child in item.items():
                    safe_string(key)
                    require(key.casefold() not in ("env", "environ", "environment"), "environment_payload")
                    pending.append((key, depth + 1))
                    pending.append((child, depth + 1))
            elif isinstance(item, list):
                require(len(item) <= 16384 - count, "tree_bound")
                pending.extend((child, depth + 1) for child in item)
            elif isinstance(item, str):
                safe_string(item)
            elif isinstance(item, float):
                require(math.isfinite(item), "nonfinite_number")
            else:
                json_type(item)
            require(count + len(pending) <= 16384, "tree_bound")
        return count

    def check_path(text, anchor, kind):
        safe_string(text)
        lexical = Path(text)
        require(lexical.is_absolute() and str(lexical) == text and ".." not in lexical.parts, "path_spelling")
        physical = contained(lexical.resolve(strict=True), anchor)
        info = physical.stat()
        if kind == "directory":
            require(stat.S_ISDIR(info.st_mode), "path_type")
        else:
            require(stat.S_ISREG(info.st_mode), "path_type")
            if kind == "executable":
                require(bool(info.st_mode & 0o111), "path_executable")
        return physical

    def prepare():
        require(type(START) is float and math.isfinite(START)
                and type(PARENT_END) is float and PARENT_END == START + 50.0
                and START <= time.monotonic() <= START + 4.0, "bootstrap_clock")
        require(BOOTSTRAP_HELPER_RELATIVE == "Scripts/check-owner-carrier-compiler-controls.py"
                and isinstance(BOOTSTRAP_HELPER_SHA256, str)
                and re.fullmatch(r"[0-9a-f]{64}", BOOTSTRAP_HELPER_SHA256) is not None
                and type(BOOTSTRAP_HELPER_BYTES) is int and 0 < BOOTSTRAP_HELPER_BYTES <= MAX_SAMPLE,
                "bootstrap_helper_shape")
        require(sys.platform == "darwin" and sys.version_info >= (3, 13), "python_feature_gate")
        require(callable(getattr(os, "waitid", None)), "python_feature_gate")
        for name in ("P_PID", "WEXITED", "WNOHANG", "WNOWAIT", "CLD_EXITED", "CLD_KILLED", "CLD_DUMPED"):
            require(hasattr(os, name), "python_feature_gate")
        require(signal.getsignal(signal.SIGCHLD) == signal.SIG_DFL, "sigchld_owner_gate")
        signal.signal(signal.SIGINT, cancelled)
        signal.signal(signal.SIGTERM, cancelled)
        checkout = Path(os.environ["GITHUB_WORKSPACE"]).resolve(strict=True)
        runner_temp = Path(os.environ["RUNNER_TEMP"]).resolve(strict=True)
        require(checkout.is_dir() and runner_temp.is_dir(), "root_shape")
        require(Path(__file__) == checkout / BOOTSTRAP_HELPER_RELATIVE
                and Path(__file__).is_absolute(), "bootstrap_helper_path")
        sample_path = Path(safe_string(os.environ["OWNER_CARRIER_METADATA_SAMPLE"]))
        require(sample_path.is_absolute(), "sample_path")
        sample_path, sample_bytes = read_regular(sample_path, runner_temp, MAX_SAMPLE)
        require(stat.S_IMODE(sample_path.lstat().st_mode) == 0o600, "sample_mode")
        require(stat.S_ISDIR(sample_path.parent.lstat().st_mode)
                and stat.S_IMODE(sample_path.parent.lstat().st_mode) == 0o700, "sample_directory_mode")
        sample = decode_json(sample_bytes)
        checked_tree(sample)
        require(isinstance(sample, dict) and set(sample) == {
            "compiler_controls", "compiler_helper", "coordinator_module", "description", "github", "kind", "schema_version",
            "selected_command", "selected_command_fields", "selected_command_key", "selected_tree_nodes",
            "semantic_fields_qualified", "source_sha256", "receipt_source_sha256", "storage_module", "workflow_sha256"}, "sample_schema")
        require(field_types(sample) == {
            "compiler_controls": "object", "compiler_helper": "object", "coordinator_module": "object", "description": "object", "github": "object",
            "kind": "string", "schema_version": "integer", "selected_command": "object", "selected_command_fields": "array",
            "selected_command_key": "string", "selected_tree_nodes": "integer", "semantic_fields_qualified": "boolean",
            "source_sha256": "object", "receipt_source_sha256": "object", "storage_module": "object",
            "workflow_sha256": "string"}, "sample_field_types")
        require(field_types(sample["compiler_controls"]) == {
            "count": "integer", "controls_per_bundle": "integer", "bundles": "array",
            "status": "string", "semantic_vectors_qualified": "boolean"}, "sample_control_types")
        require(field_types(sample["compiler_helper"]) == {
            "relative_path": "string", "sha256": "string", "bytes": "integer"}, "sample_helper_types")
        require(sample["compiler_helper"] == {
            "relative_path": BOOTSTRAP_HELPER_RELATIVE, "sha256": BOOTSTRAP_HELPER_SHA256,
            "bytes": BOOTSTRAP_HELPER_BYTES}, "sample_helper_pin")
        require(field_types(sample["storage_module"]) == {
            "relative_to_description_parent": "string", "exists": "boolean", "freshness_proven": "boolean",
            "import_proven": "boolean"}, "sample_storage_module_types")
        require(field_types(sample["coordinator_module"]) == {
            "relative_to_description_parent": "string", "exists": "boolean", "freshness_proven": "boolean",
            "import_proven": "boolean"}, "sample_module_types")
        require(field_types(sample["description"]) == {
            "requested_relative_path": "string", "resolved_relative_path": "string", "sha256": "string", "bytes": "integer",
            "top_level_fields": "array", "swift_commands_count": "integer"}, "sample_description_types")
        require(type(sample["schema_version"]) is int and sample["schema_version"] == 2
                and sample["kind"] == "METADATA_ONLY_COMPILER_CONTROLS_HELD"
                and sample["semantic_fields_qualified"] is False
                and sample["compiler_controls"] == {"count": 6, "controls_per_bundle": 3, "bundles": ["origin", "receipt"], "status": "HELD", "semantic_vectors_qualified": False},
                "sample_contract")
        sha, run_id, attempt = (os.environ[name] for name in ("GITHUB_SHA", "GITHUB_RUN_ID", "GITHUB_RUN_ATTEMPT"))
        require(re.fullmatch(r"[0-9a-f]{40}", sha) is not None
                and re.fullmatch(r"[1-9][0-9]{0,19}", run_id) is not None
                and re.fullmatch(r"[1-9][0-9]{0,9}", attempt) is not None, "run_shape")
        require(sample["github"] == {"sha": sha, "run_id": run_id, "run_attempt": attempt}, "same_run_pin")
        require(sample["source_sha256"] == SOURCE_PINS, "sample_source_pin")
        for relative, expected in SOURCE_PINS.items():
            _, content = read_regular(checkout / relative, checkout, MAX_INPUT)
            require(hashlib.sha256(content).hexdigest() == expected, "current_source_pin")
        require(sample["receipt_source_sha256"] == RECEIPT_SOURCE_PINS, "sample_receipt_source_pin")
        for relative, expected in RECEIPT_SOURCE_PINS.items():
            _, content = read_regular(checkout / relative, checkout, MAX_INPUT)
            require(hashlib.sha256(content).hexdigest() == expected, "current_receipt_source_pin")
        for relative, expected in (
            ("Package.swift", "26f047e638070a05f3926d5d5798251cc76f1c50ee628c1415696bef43d3a8be"),
            ("Package.resolved", "2ccd523e0a9073145aa6b835a1fe00b252ba476b19c24851c9c355ca481d0ce1"),
        ):
            _, content = read_regular(checkout / relative, checkout, MAX_INPUT)
            require(hashlib.sha256(content).hexdigest() == expected, "package_pin")
        _, workflow = read_regular(checkout / ".github/workflows/ci.yml", checkout, MAX_INPUT)
        require(sample["workflow_sha256"] == hashlib.sha256(workflow).hexdigest(), "workflow_pin")
        build = contained((checkout / ".build").resolve(strict=True), checkout)
        require(build.is_dir(), "build_shape")
        description_path, description_bytes = read_regular(checkout / ".build/debug/description.json", build, MAX_INPUT)
        physical_debug = contained((build / "arm64-apple-macosx/debug").resolve(strict=True), build)
        require(description_path == physical_debug / "description.json", "description_path")
        description = decode_json(description_bytes)
        require(field_types(description) == TOP_FIELDS, "description_schema")
        commands = description["swiftCommands"]
        require(isinstance(commands, dict) and len(commands) <= 256
                and all(isinstance(value, dict) for value in commands.values()), "commands_shape")
        matches = [(key, value) for key, value in commands.items()
                   if isinstance(value.get("moduleName"), str) and value["moduleName"] == "CoordinatorTests"]
        require(len(matches) == 1, "command_selection")
        key, command = matches[0]
        require(key == sample["selected_command_key"] == "C.CoordinatorTests-arm64-apple-macosx-debug.module",
                "command_key")
        require(field_types(command) == FIELD_TYPES and len(command) == 15, "command_schema")
        require(field_types(sample["selected_command"]) == FIELD_TYPES
                and command == sample["selected_command"], "sample_command_pin")
        require(checked_tree(command) == sample["selected_tree_nodes"], "sample_tree_pin")
        require(sample["selected_command_fields"] == [{"key": name, "type": value} for name, value in FIELD_TYPES.items()],
                "sample_field_pin")
        require(sample["description"] == {
            "requested_relative_path": ".build/debug/description.json",
            "resolved_relative_path": str(description_path.relative_to(checkout)),
            "sha256": hashlib.sha256(description_bytes).hexdigest(), "bytes": len(description_bytes),
            "top_level_fields": [{"key": name, "type": value} for name, value in TOP_FIELDS.items()],
            "swift_commands_count": len(commands)}, "description_pin")
        require(sample["coordinator_module"] == {
            "relative_to_description_parent": "Modules/Coordinator.swiftmodule", "exists": True,
            "freshness_proven": False, "import_proven": False}, "module_sample_shape")
        debug = str(checkout / ".build/arm64-apple-macosx/debug")
        source_paths = [str(checkout / "Tests/CoordinatorTests" / name) for name in SOURCE_NAMES]
        object_paths = [debug + "/CoordinatorTests.build/" + name + ".o" for name in SOURCE_NAMES]
        arguments = [text.replace("{CHECKOUT}", str(checkout)) for text in ARGUMENT_TEMPLATE]
        expected = {
            "executable": COMPILER, "fileList": debug + "/CoordinatorTests.build/sources",
            "importPath": debug + "/Modules", "inputs": [{"kind": "file", "name": name} for name in source_paths + [
                debug + "/swift-version-7974D3F7F03D5E95.txt", debug + "/Modules/Coordinator.swiftmodule",
                debug + "/Modules/NIOTransport.swiftmodule", debug + "/CoordinatorTests.build/sources"]],
            "isLibrary": True, "moduleName": "CoordinatorTests", "moduleOutputPath": debug + "/Modules/CoordinatorTests.swiftmodule",
            "objects": object_paths, "otherArguments": arguments,
            "outputFileMapPath": debug + "/CoordinatorTests.build/output-file-map.json",
            "outputs": [{"kind": "file", "name": name} for name in object_paths + [debug + "/Modules/CoordinatorTests.swiftmodule"]],
            "prepareForIndexing": False, "sources": source_paths, "tempsPath": debug + "/CoordinatorTests.build",
            "wholeModuleOptimization": False,
        }
        require(command == expected and len(arguments) == 116
                and sum(len(token.encode("utf-8")) + 1 for token in arguments) <= 65536, "exact_profile")
        require(sum(text.endswith(".swift") for text in arguments) == 0
                and not any(text.startswith("@") for text in arguments), "source_input_profile")
        for source in source_paths:
            check_path(source, checkout / "Tests/CoordinatorTests", "file")
        app = Path("/Applications/Xcode_26.6.app").resolve(strict=True)
        developer = check_path(DEVELOPER, app, "directory")
        toolchain = check_path(TOOLCHAIN, developer, "directory")
        platform = check_path(PLATFORM, developer, "directory")
        check_path(COMPILER, toolchain, "executable")
        check_path(SDK, platform, "directory")
        check_path(TOOLCHAIN + "/usr/lib/swift/host/plugins/testing", toolchain, "directory")
        check_path(PLATFORM + "/Library/Frameworks", platform, "directory")
        check_path(PLATFORM + "/usr/lib", platform, "directory")
        modules = check_path(command["importPath"], physical_debug, "directory")
        for name in ("Coordinator.swiftmodule", "NIOTransport.swiftmodule", "CoordinatorTests.swiftmodule"):
            check_path(debug + "/Modules/" + name, modules, "file")
        storage_path = physical_debug / "Modules/WorkspaceStorage.swiftmodule"
        storage_exists = os.path.lexists(storage_path)
        if storage_exists:
            require(stat.S_ISREG(storage_path.lstat().st_mode), "storage_module_shape")
            require(check_path(str(storage_path), modules, "file") == modules / "WorkspaceStorage.swiftmodule",
                    "storage_module_path")
        require(sample["storage_module"] == {
            "relative_to_description_parent": "Modules/WorkspaceStorage.swiftmodule", "exists": storage_exists,
            "freshness_proven": False, "import_proven": False}, "storage_module_sample_shape")
        if BUNDLE == "receipt":
            require(storage_exists, "storage_module_missing")
        checkouts = check_path(str(checkout / ".build/checkouts"), build, "directory")
        for start in range(15, 81, 6):
            modulemap = arguments[start + 1].split("=", 1)[1]
            include = arguments[start + 5]
            relative_include = Path(include).relative_to(checkout / ".build/checkouts")
            dependency = check_path(str(checkout / ".build/checkouts" / relative_include.parts[0]), checkouts, "directory")
            include_physical = check_path(include, dependency, "directory")
            if modulemap.startswith(debug + "/"):
                target_build = check_path(str(Path(modulemap).parent), physical_debug, "directory")
                check_path(modulemap, target_build, "file")
            else:
                check_path(modulemap, include_physical, "file")
        private = Path(tempfile.mkdtemp(prefix="owner-carrier-controls-", dir=runner_temp))
        os.chmod(private, 0o700)
        require(stat.S_ISDIR(private.lstat().st_mode) and stat.S_IMODE(private.lstat().st_mode) == 0o700,
                "private_directory_mode")
        safe_string(str(private))
        cache = private / "ModuleCache"
        cache.mkdir(mode=0o700)
        require(stat.S_ISDIR(cache.lstat().st_mode) and stat.S_IMODE(cache.lstat().st_mode) == 0o700,
                "cache_directory_mode")
        normalized = []
        dropped = {2, 3, 4, 5, 6, 83, 101, 112, 113}
        for index, token in enumerate(arguments):
            if index not in dropped:
                normalized.append("-j1" if index == 11 else str(cache) if index == 82 else token)
        require(len(normalized) == 107, "normalized_count")
        common = [COMPILER, "-typecheck", *normalized, "-module-name", MODULE_NAME,
                  "-no-color-diagnostics", "-I", command["importPath"]]
        controls = []
        for name, text, expected_hash in FIXTURES:
            data = text.encode("utf-8")
            require(hashlib.sha256(data).hexdigest() == expected_hash, "fixture_pin")
            path = private / name
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            with os.fdopen(fd, "wb") as stream:
                os.fchmod(stream.fileno(), 0o600)
                require(stream.write(data) == len(data), "fixture_write")
                stream.flush()
                os.fsync(stream.fileno())
                info = os.fstat(stream.fileno())
                require(stat.S_ISREG(info.st_mode) and info.st_size == len(data)
                        and stat.S_IMODE(info.st_mode) == 0o600, "fixture_file_shape")
            argv = [*common, str(path)]
            require(len(argv) == 115 and sum(len(token.encode("utf-8")) + 1 for token in argv) <= 65536
                    and sum(token.endswith(".swift") for token in argv) == 1
                    and not any(token.startswith("@") for token in argv), "final_argv_shape")
            controls.append((path, text, argv, expected_hash))
        child_env = {"PATH": TOOLCHAIN + "/usr/bin:/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C",
                     "DEVELOPER_DIR": DEVELOPER, "TMPDIR": str(private)}
        require(not CANCELLED and time.monotonic() <= START + 4.0, "preparation_budget")
        emit("owner_carrier_compiler_profile", schema_fields=15, original_tokens=116, normalized_tokens=107,
             sources=46, inputs=50, outputs=47, sample_sha256=hashlib.sha256(sample_bytes).hexdigest(),
             description_sha256=hashlib.sha256(description_bytes).hexdigest(), workflow_sha256=sample["workflow_sha256"],
             normal_driver_job_completion_trusted=True, descendant_quiescence_proven=False)
        require(not CANCELLED and time.monotonic() <= START + 4.0, "preparation_budget")
        return checkout, child_env, controls

    class Owner:
        __slots__ = ("process", "valid", "terminal", "reaped", "reap_attempted", "data", "eof", "closed", "ordinal")
        def __init__(self, ordinal):
            self.process = None
            self.valid = False
            self.terminal = None
            self.reaped = False
            self.reap_attempted = False
            self.data = bytearray()
            self.eof = False
            self.closed = False
            self.ordinal = ordinal

    def observe(owner):
        require(owner.valid and not owner.reaped and not owner.reap_attempted, "owned_wait_state")
        if owner.terminal is not None:
            return owner.terminal
        try:
            event = os.waitid(os.P_PID, owner.process.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT)
        except BaseException:
            owner.valid = False
            raise Failure("waitid_failure") from None
        if event is not None:
            if event.si_pid != owner.process.pid or event.si_code not in (os.CLD_EXITED, os.CLD_KILLED, os.CLD_DUMPED):
                owner.valid = False
                raise Failure("waitid_shape")
            owner.terminal = (event.si_code, event.si_status)
        return owner.terminal

    def close_capture(owner):
        if owner.process is not None and owner.process.stdout is not None and not owner.closed:
            owner.closed = True
            owner.process.stdout.close()

    def drain(owner):
        if owner.eof or owner.closed:
            return
        try:
            data = os.read(owner.process.stdout.fileno(), min(8192, MAX_OUTPUT + 1 - len(owner.data)))
        except BlockingIOError:
            return
        if not data:
            owner.eof = True
            return
        remaining = MAX_OUTPUT - len(owner.data)
        owner.data.extend(data[:remaining])
        if len(data) > remaining:
            close_capture(owner)
            raise Failure("output_overflow")

    def reap(owner, deadline):
        require(owner.valid and owner.terminal is not None and not owner.reap_attempted, "reap_state")
        owner.reap_attempted = True
        try:
            result = owner.process.wait(timeout=max(0.0, min(0.1, deadline - time.monotonic())))
        except BaseException:
            owner.valid = False
            raise Failure("reap_failure") from None
        owner.reaped = True
        owner.valid = False
        code, status = owner.terminal
        expected = status if code == os.CLD_EXITED else -status
        require(result == expected, "reap_mismatch")
        return result

    def raw_signal(owner, number):
        if observe(owner) is not None:
            return False
        try:
            os.kill(owner.process.pid, number)
        except ProcessLookupError:
            require(observe(owner) is not None, "signal_lookup_uncertain")
            return False
        except BaseException:
            owner.valid = False
            raise Failure("signal_failure") from None
        return True

    def failed_cleanup(owner):
        global FAILURE_CLEANUP_USED
        receipt = {"direct_reaped": owner.reaped, "cooperative_sigint": False,
                   "forced_direct_sigkill": False, "cleanup_uncertain": True,
                   "residual_process_risk": True, "descendant_quiescence_proven": False}
        if FAILURE_CLEANUP_USED or owner.process is None or owner.reaped or owner.reap_attempted or not owner.valid:
            return receipt
        FAILURE_CLEANUP_USED = True
        start = time.monotonic()
        end = min(start + 7.0, PARENT_END - 3.0)
        try:
            event = observe(owner)
            if event is None and time.monotonic() < end:
                receipt["cooperative_sigint"] = raw_signal(owner, signal.SIGINT)
                grace = min(start + 6.0, end)
                while observe(owner) is None and time.monotonic() < grace:
                    try:
                        drain(owner)
                    except Failure:
                        close_capture(owner)
                    time.sleep(max(0.0, min(0.02, grace - time.monotonic())))
            if observe(owner) is None and time.monotonic() < end:
                receipt["forced_direct_sigkill"] = raw_signal(owner, signal.SIGKILL)
                while observe(owner) is None and time.monotonic() < end:
                    time.sleep(max(0.0, min(0.01, end - time.monotonic())))
            if owner.terminal is not None and time.monotonic() <= end:
                reap(owner, end)
        except BaseException:
            owner.valid = False
        receipt["direct_reaped"] = owner.reaped
        receipt["cleanup_uncertain"] = True
        return receipt

    INIT_MESSAGES = (
        "'init(hub:database:baseURL:reference:store:makeAPI:)' is inaccessible due to 'fileprivate' protection level",
        "'HubSync.ConfiguredClientOrigin' initializer is inaccessible due to 'fileprivate' protection level",
        "'ConfiguredClientOrigin' initializer is inaccessible due to 'fileprivate' protection level",
    )
    IDENTITY_MESSAGE = "cannot assign to property: 'identity' is a 'let' constant"
    INIT_NOTE = "'init(hub:database:baseURL:reference:store:makeAPI:)' declared here"
    IDENTITY_NOTES = ("change 'let' to 'var' to make it mutable", "'identity' declared here")

    def auxiliary_note(header, context_lines, note_messages):
        _file_name, line_text, col_text, severity, message = header
        require(len(line_text) <= 5 and len(col_text) <= 5, "declaration_note_location")
        line_number, column = int(line_text), int(col_text)
        require(1 <= line_number <= 10000 and 1 <= column <= 10000, "declaration_note_location")
        require(severity == "note" and message in note_messages, "declaration_note")
        width = None
        seen = []
        annotations = 0
        for rendered in context_lines:
            if rendered == "":
                continue
            if width is not None:
                annotation = " " * (width + 1) + "| " + " " * (column - 1) + "`- note: " + message
                if rendered == annotation:
                    require(bool(seen) and seen[-1] == line_number and annotations == 0, "diagnostic_annotation")
                    annotations += 1
                    continue
            match = re.fullmatch(r"( {0,4})([1-9][0-9]{0,4}) \| (.*)", rendered)
            require(match is not None, "diagnostic_context_form")
            padding, number_text, value = match.groups()
            number = int(number_text)
            row_width = len(padding) + len(number_text)
            if width is None:
                width = row_width
            require(1 <= number <= 10000 and 1 <= width <= 5 and row_width == width
                    and rendered == f"{number:>{width}} | {value}", "diagnostic_context_text")
            require(not seen or number == seen[-1] + 1, "diagnostic_context_order")
            seen.append(number)
        require(line_number in seen and annotations == 1, "diagnostic_context_missing")

    def diagnostics(data, ordinal, path, fixture, checkout):
        if ordinal == 1:
            require(not data, "positive_output")
            return 0, 0, 0
        try:
            text = data.decode("ascii")
        except UnicodeError:
            raise Failure("diagnostic_decode") from None
        require(not any((ord(c) < 32 and c != "\n") or 127 <= ord(c) <= 159 for c in text), "diagnostic_control")
        source = {index + 1: value for index, value in enumerate(fixture.split("\n"))}
        if BUNDLE == "origin":
            error_line = 3 if ordinal == 2 else 4
            target = source[error_line]
            columns = ({target.index("HubSync") + 1, target.index("ConfiguredClientOrigin") + 1, target.index("init(") + 1}
                       if ordinal == 2 else {target.index("original") + 1, target.index("identity") + 1})
            messages = INIT_MESSAGES if ordinal == 2 else (IDENTITY_MESSAGE,)
            note_messages = (INIT_NOTE,) if ordinal == 2 else IDENTITY_NOTES
        else:
            error_line = 3 if ordinal == 2 else 4
            columns = {17, 48} if ordinal == 2 else {3, 12}
            messages = ("'ProtocolOwnedProofWriteReceipt' initializer is inaccessible due to 'fileprivate' protection level",) if ordinal == 2 else (
                            "cannot assign to property: 'disposition' is a get-only property",)
            note_messages = ("'init(payload:)' declared here",) if ordinal == 2 else ("'disposition' declared here",)
        raw_lines = text.splitlines()
        require(len(raw_lines) <= 24 and raw_lines.count("") <= 4, "diagnostic_line_bound")
        blocks = []
        for line in raw_lines:
            match = re.fullmatch(r"(.+):([1-9][0-9]*):([1-9][0-9]*): (error|note|warning): (.+)", line)
            if match:
                blocks.append((match.groups(), []))
            else:
                require(bool(blocks), "diagnostic_header")
                blocks[-1][1].append(line)
        require(1 <= len(blocks) <= 2, "diagnostic_block_count")
        for index, (header, context_lines) in enumerate(blocks):
            file_name, line_text, col_text, severity, message = header
            line_number, column = int(line_text), int(col_text)
            if index == 0:
                require(file_name == str(path) and line_number == error_line and column in columns
                        and severity == "error" and message in messages, "intended_error")
                allowed, width = source, 1
            else:
                auxiliary_note(header, context_lines, note_messages)
                continue
            seen = []
            annotations = 0
            for rendered in context_lines:
                if rendered == "":
                    continue
                annotation = " " * (width + 1) + "| " + " " * (column - 1) + "`- " + severity + ": " + message
                if rendered == annotation:
                    require(bool(seen) and seen[-1] == line_number and annotations == 0, "diagnostic_annotation")
                    annotations += 1
                    continue
                match = re.fullmatch(r"([ 0-9]{1,2}) \| (.*)", rendered)
                require(match is not None, "diagnostic_context_form")
                number_text, value = match.groups()
                number = int(number_text)
                require(number in allowed and value == allowed[number]
                        and rendered == f"{number:>{width}} | {allowed[number]}", "diagnostic_context_text")
                require(not seen or number == seen[-1] + 1, "diagnostic_context_order")
                seen.append(number)
            require(line_number in seen and annotations == 1, "diagnostic_context_missing")
        return error_line, int(blocks[0][0][2]), len(blocks) - 1

    def run_control(ordinal, control, checkout, child_env):
        path, fixture, argv, fixture_hash = control
        require(not CANCELLED and time.monotonic() + 22.0 <= PARENT_END, "launch_budget")
        owner = Owner(ordinal)
        OWNERS.append(owner)
        deadline = time.monotonic() + 12.0
        try:
            owner.process = subprocess.Popen(argv, cwd=checkout, env=child_env, stdin=subprocess.DEVNULL,
                                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT, bufsize=0,
                                             shell=False, close_fds=True, start_new_session=True)
        except BaseException:
            raise Failure("launch_failure") from None
        require(type(owner.process.pid) is int and owner.process.pid > 0, "owned_pid_shape")
        owner.valid = True
        try:
            os.set_blocking(owner.process.stdout.fileno(), False)
        except BaseException:
            close_capture(owner)
            raise Failure("capture_setup") from None
        selector = selectors.DefaultSelector()
        try:
            selector.register(owner.process.stdout, selectors.EVENT_READ)
            registered = True
            while True:
                require(not CANCELLED, "cancelled")
                require(time.monotonic() < deadline, "normal_deadline")
                drain(owner)
                if owner.eof and registered:
                    selector.unregister(owner.process.stdout)
                    registered = False
                terminal = observe(owner)
                if terminal is not None:
                    require(terminal[0] == os.CLD_EXITED, "child_signal")
                    require(terminal[1] == (0 if ordinal == 1 else 1), "child_exit_status")
                    if owner.eof:
                        break
                selector.select(timeout=max(0.0, min(0.02, deadline - time.monotonic())))
            require(owner.terminal[0] == os.CLD_EXITED, "child_signal")
            require(owner.terminal[1] == (0 if ordinal == 1 else 1), "child_exit_status")
            reap(owner, deadline)
            line, column, notes = diagnostics(bytes(owner.data), ordinal, path, fixture, checkout)
            require(not CANCELLED and time.monotonic() < deadline, "normal_deadline")
            emit("owner_carrier_control_qualified", ordinal=ordinal, raw_exit_status=0 if ordinal == 1 else 1,
                 fixture_sha256=fixture_hash, vector_sha256=hashlib.sha256(json.dumps(argv, separators=(",", ":")).encode()).hexdigest(),
                 output_sha256=hashlib.sha256(owner.data).hexdigest(), captured_bytes=len(owner.data),
                 diagnostic_errors=0 if ordinal == 1 else 1, diagnostic_notes=notes,
                 line=line, column=column, direct_reaped=True, normal_driver_job_completion_trusted=True,
                 descendant_quiescence_proven=False)
        finally:
            selector.close()
        require(not CANCELLED and time.monotonic() < deadline, "normal_deadline")

    def main():
        checkout, child_env, controls = prepare()
        for ordinal, control in enumerate(controls, 1):
            run_control(ordinal, control, checkout, child_env)
        require(not CANCELLED and time.monotonic() < PARENT_END - 3.0, "parent_budget")

    result = 1
    reason = "infrastructure_failure"
    cleanup_receipts = []
    try:
        main()
        result = 0
    except Failure as failure:
        reason = failure.code
    except BaseException:
        reason = "infrastructure_failure"
    if result:
        for owner in OWNERS:
            if owner.process is not None and not owner.reaped:
                cleanup_receipts.append(failed_cleanup(owner))
    for owner in OWNERS:
        try:
            close_capture(owner)
        except BaseException:
            result = 1
            reason = "descriptor_close_failure"
    require(time.monotonic() < PARENT_END, "parent_budget")
    for receipt in cleanup_receipts:
        emit("owner_carrier_failed_cleanup", **receipt)
    if result:
        emit("owner_carrier_compiler_controls_failed", reason=reason, compiler_controls_qualified=False,
             descendant_quiescence_proven=False)
    else:
        require(not CANCELLED, "cancelled")
        emit("owner_carrier_compiler_controls_qualified", controls=3,
             normal_driver_job_completion_trusted=True, descendant_quiescence_proven=False)
    sys.stdout.flush()
    sys.stderr.flush()
    if result == 0:
        require(not CANCELLED, "cancelled")
        require(time.monotonic() < PARENT_END, "parent_budget")
    os._exit(result)

except BaseException:
    for retained in globals().get("OWNERS", []):
        try:
            if retained.process is not None and not retained.reaped:
                failed_cleanup(retained)
        except BaseException:
            pass
        try:
            close_capture(retained)
        except BaseException:
            pass
    try:
        print('{"category":"owner_carrier_infrastructure_failure"}', flush=True)
        if "sys" in globals():
            sys.stdout.flush()
            sys.stderr.flush()
    finally:
        if "os" in globals():
            os._exit(1)
        raise SystemExit(1)
