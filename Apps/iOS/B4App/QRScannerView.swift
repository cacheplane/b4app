@preconcurrency import AVFoundation
import SwiftUI
import UIKit
import WorkspaceUI

/// Scans the pairing QR code the Mac shows. It hands back the first QR code's text and stops; the
/// caller decides what it means. Offered only where a camera exists (`isAvailable`), so never in the
/// Simulator. Nothing it reads is logged.
struct QRScannerView: View {
  let onScan: (String) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var access: Access = .checking

  enum Access { case checking, granted, denied }

  /// A camera exists on this device.
  static var isAvailable: Bool { AVCaptureDevice.default(for: .video) != nil }

  var body: some View {
    NavigationStack {
      Group {
        switch access {
        case .checking:
          ProgressView()
        case .granted:
          QRCameraPreview { text in
            onScan(text)
            dismiss()
          }
          .ignoresSafeArea(edges: .bottom)
        case .denied:
          Text(
            "Camera access is off for Agent Workspace. Allow it in Settings, or type the hub URL and code instead."
          )
          .font(LLAFont.small)
          .foregroundStyle(LLA.Color.ink)
          .padding(LLA.Metrics.margin)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(LLA.Color.bg)
      .navigationTitle("Scan QR code")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
      }
    }
    .task { access = await Self.requestAccess() }
  }

  private static func requestAccess() async -> Access {
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized: return .granted
    case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video) ? .granted : .denied
    default: return .denied
    }
  }
}

/// The camera's preview with a QR metadata output.
private struct QRCameraPreview: UIViewControllerRepresentable {
  let onCode: @MainActor (String) -> Void

  func makeUIViewController(context: Context) -> QRCameraController {
    QRCameraController(onCode: onCode)
  }

  func updateUIViewController(_ controller: QRCameraController, context: Context) {}
}

private final class QRCameraController: UIViewController {
  private let capture: QRCapture
  private var preview: AVCaptureVideoPreviewLayer?

  init(onCode: @escaping @MainActor (String) -> Void) {
    capture = QRCapture { text in MainActor.assumeIsolated { onCode(text) } }
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("not used from a storyboard") }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .black
    let layer = AVCaptureVideoPreviewLayer(session: capture.session)
    layer.videoGravity = .resizeAspectFill
    view.layer.addSublayer(layer)
    preview = layer
    capture.configure()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    preview?.frame = view.bounds
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    capture.start()
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    capture.stop()
  }
}

/// The capture session and its metadata delegate. The session is configured, started, and stopped on
/// its own queue (`startRunning` blocks); QR codes arrive on the main queue, and only the first is
/// handed on.
private nonisolated final class QRCapture: NSObject, AVCaptureMetadataOutputObjectsDelegate,
  @unchecked Sendable
{
  let session = AVCaptureSession()
  private let queue = DispatchQueue(label: "b4app.qr-capture")
  /// Called on the main queue.
  private let onCode: @Sendable (String) -> Void
  /// Touched only on the main queue.
  private var delivered = false

  init(onCode: @escaping @Sendable (String) -> Void) {
    self.onCode = onCode
  }

  func configure() {
    queue.async { [self] in
      session.beginConfiguration()
      defer { session.commitConfiguration() }
      guard let camera = AVCaptureDevice.default(for: .video),
        let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input)
      else { return }
      session.addInput(input)
      let output = AVCaptureMetadataOutput()
      guard session.canAddOutput(output) else { return }
      session.addOutput(output)
      output.setMetadataObjectsDelegate(self, queue: .main)
      if output.availableMetadataObjectTypes.contains(.qr) { output.metadataObjectTypes = [.qr] }
    }
  }

  func start() {
    queue.async { [self] in
      if !session.isRunning { session.startRunning() }
    }
  }

  func stop() {
    queue.async { [self] in
      if session.isRunning { session.stopRunning() }
    }
  }

  func metadataOutput(
    _ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject],
    from connection: AVCaptureConnection
  ) {
    guard !delivered else { return }
    for object in metadataObjects {
      guard let code = object as? AVMetadataMachineReadableCodeObject, code.type == .qr,
        let text = code.stringValue
      else { continue }
      delivered = true
      stop()
      onCode(text)
      return
    }
  }
}
