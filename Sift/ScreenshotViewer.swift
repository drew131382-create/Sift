import SwiftUI
import UIKit

struct ScreenshotViewer: View {
    let url: URL?
    let title: String
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let image {
                    ZoomableScreenshot(image: image).accessibilityLabel("原始截图，可双指缩放或双击放大")
                        .accessibilityIdentifier("screenshot.canvas")
                } else if loaded {
                    ContentUnavailableView("原图暂时无法打开", systemImage: "photo", description: Text("本地图片可能已丢失，信息卡仍可查看。"))
                        .foregroundStyle(.white).accessibilityIdentifier("screenshot.missing")
                } else { ProgressView("正在打开原图…").tint(.white).foregroundStyle(.white) }
            }
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(.black, for: .navigationBar).toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }.frame(minWidth: 44, minHeight: 44)
                        .accessibilityIdentifier("screenshot.close")
                }
            }
            .task {
                if let url { image = await Task.detached(priority: .userInitiated) { UIImage(contentsOfFile: url.path) }.value }
                loaded = true
            }
        }
    }
}

private struct ZoomableScreenshot: UIViewRepresentable {
    let image: UIImage
    func makeUIView(context: Context) -> ScreenshotCanvas { ScreenshotCanvas() }
    func updateUIView(_ uiView: ScreenshotCanvas, context: Context) { uiView.setImage(image) }
}

private final class ScreenshotCanvas: UIScrollView, UIScrollViewDelegate {
    private let imageView = UIImageView()
    private var previousSize: CGSize = .zero
    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 6
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        backgroundColor = .black
        imageView.contentMode = .scaleAspectFit
        addSubview(imageView)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(zoomAtTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
        accessibilityHint = "双击放大，再次双击恢复；双指缩放后可拖动图片。"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func setImage(_ image: UIImage) {
        guard imageView.image !== image else { return }
        imageView.image = image
        previousSize = .zero
        setNeedsLayout()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != previousSize, bounds.width > 0, bounds.height > 0, let image = imageView.image else { return }
        previousSize = bounds.size
        zoomScale = 1
        let fit = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = CGSize(width: image.size.width * fit, height: image.size.height * fit)
        imageView.frame = CGRect(origin: .zero, size: size)
        contentSize = size
        centerImage()
    }
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerImage() }
    private func centerImage() {
        let vertical = max(0, (bounds.height - contentSize.height) / 2)
        let horizontal = max(0, (bounds.width - contentSize.width) / 2)
        contentInset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
    }
    @objc private func zoomAtTap(_ gesture: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale { setZoomScale(minimumZoomScale, animated: !UIAccessibility.isReduceMotionEnabled); return }
        let point = gesture.location(in: imageView)
        let scale: CGFloat = 3
        let rectangle = CGRect(x: point.x - bounds.width / scale / 2, y: point.y - bounds.height / scale / 2, width: bounds.width / scale, height: bounds.height / scale)
        zoom(to: rectangle, animated: !UIAccessibility.isReduceMotionEnabled)
    }
}
