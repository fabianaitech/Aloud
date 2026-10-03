// Images.swift — pictures that came with a response: what Claude looked at in
// the turn (screenshots, diagrams), and image files or web images it linked.

import SwiftUI

/// A picture held by the Mac, loaded once and cached.
struct MacImage: View {
    @EnvironmentObject var model: AppModel
    let name: String
    var contentMode: ContentMode = .fill
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if failed {
                Image(systemName: "photo.badge.exclamationmark")
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
        .task(id: name) {
            image = await model.image(named: name)
            failed = image == nil
        }
    }
}

/// The turn's pictures under a response: a row of thumbnails, tap to open.
struct ImageStrip: View {
    let names: [String]
    @State private var open: ViewerItem?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(names.enumerated()), id: \.offset) { i, name in
                    Button { open = ViewerItem(names: names, index: i) } label: {
                        MacImage(name: name)
                            .frame(width: 112, height: 112)
                            .background(Color(.tertiarySystemFill))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(.quaternary))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Image \(i + 1) of \(names.count)")
                }
            }
        }
        .fullScreenCover(item: $open) { ImageViewer(item: $0) }
    }
}

struct ViewerItem: Identifiable {
    let names: [String]
    let index: Int
    var id: String { "\(index)-\(names.joined())" }
}

/// Full screen: swipe between the turn's pictures, pinch or double-tap to zoom.
struct ImageViewer: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let item: ViewerItem
    @State private var page = 0

    var body: some View {
        NavigationStack {
            TabView(selection: $page) {
                ForEach(Array(item.names.enumerated()), id: \.offset) { i, name in
                    ZoomableMacImage(name: name).tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: item.names.count > 1 ? .automatic : .never))
            .background(.black)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarLeading) { ShareImage(name: item.names[page]) }
            }
            .toolbarBackground(.black, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .onAppear { page = item.index }
    }
}

struct ZoomableMacImage: View {
    let name: String
    @State private var scale: CGFloat = 1
    @State private var last: CGFloat = 1

    var body: some View {
        MacImage(name: name, contentMode: .fit)
            .scaleEffect(scale)
            .gesture(MagnifyGesture()
                .onChanged { scale = max(1, min(6, last * $0.magnification)) }
                .onEnded { _ in last = scale })
            .onTapGesture(count: 2) {
                withAnimation(.snappy) { scale = scale > 1 ? 1 : 2.5; last = scale }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ShareImage: View {
    @EnvironmentObject var model: AppModel
    let name: String
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                ShareLink(item: Image(uiImage: image), preview: SharePreview("Image", image: Image(uiImage: image)))
            } else {
                Image(systemName: "square.and.arrow.up").foregroundStyle(.secondary)
            }
        }
        .task(id: name) { image = await model.image(named: name) }
    }
}

/// An image linked in the markdown: one the Mac copied (aloud-image:), or a
/// web image the phone loads itself.
struct MarkdownImage: View {
    let alt: String
    let src: String

    var body: some View {
        Group {
            if src.hasPrefix("aloud-image:") {
                ImageStrip(names: [String(src.dropFirst("aloud-image:".count))])
            } else if let url = URL(string: src), url.scheme == "https" || url.scheme == "http" {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let img): img.resizable().scaledToFit()
                    case .failure: Label(alt.isEmpty ? "Image" : alt, systemImage: "photo.badge.exclamationmark")
                    default: ProgressView()
                    }
                }
                .frame(maxHeight: 260)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                Label(alt.isEmpty ? src : alt, systemImage: "photo")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel(alt.isEmpty ? "Image" : alt)
    }
}
