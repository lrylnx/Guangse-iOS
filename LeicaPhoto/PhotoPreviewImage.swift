import SwiftUI
import UIKit

/// UIImageView explicitly opts into EDR. A plain SDR SwiftUI rendering pass can
/// flatten the PQ preview even when the underlying CGImage retains HDR pixels.
struct PhotoPreviewImage: UIViewRepresentable {
    let image: UIImage
    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView()
        view.contentMode = .scaleAspectFit
        view.preferredImageDynamicRange = .high
        view.clipsToBounds = true
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return view
    }
    func updateUIView(_ view: UIImageView, context: Context) { view.image = image }
}
