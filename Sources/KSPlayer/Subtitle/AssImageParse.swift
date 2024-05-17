//
//  AssImageParse.swift
//
//
//  Created by kintan on 5/4/24.
//

import Foundation
import libass
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

public final class AssImageParse: KSParseProtocol {
    public func canParse(scanner: Scanner) -> Bool {
        guard scanner.scanString("[Script Info]") != nil else {
            return false
        }
        return true
    }

    public func parsePart(scanner _: Scanner) -> SubtitlePart? {
        nil
    }

    public func parse(scanner: Scanner) -> KSSubtitleProtocol {
        AssImageRenderer(content: scanner.string)
    }
}

public final actor AssImageRenderer {
    private let library: OpaquePointer?
    private let renderer: OpaquePointer?
    private var currentTrack: UnsafeMutablePointer<ASS_Track>?
    public init(content: String? = nil) {
        library = ass_library_init()
        renderer = ass_renderer_init(library)
        ass_set_extract_fonts(library, 1)
        ass_set_fonts_dir(library, KSOptions.fontsDir)
        // 用FONTCONFIG会比较耗时，并且文字可能会大小不一致
        ass_set_fonts(renderer, nil, nil, Int32(ASS_FONTPROVIDER_AUTODETECT.rawValue), nil, 1)
        if let content, var buffer = content.cString(using: .utf8) {
            currentTrack = ass_read_memory(library, &buffer, buffer.count, nil)
        } else {
            currentTrack = ass_new_track(library)
        }
        setFrame(size: CGSize(width: 1024, height: 540))
    }

    public func subtitle(header: String) {
        if var buffer = header.cString(using: .utf8) {
            ass_process_codec_private(currentTrack, &buffer, Int32(buffer.count))
        }
    }

    public func add(subtitle: String, start: Int64, duration: Int64) {
        if var buffer = subtitle.cString(using: .utf8) {
            ass_process_chunk(currentTrack, &buffer, Int32(buffer.count), start, duration)
        }
    }

    public func setFrame(size: CGSize) {
        ass_set_frame_size(renderer, Int32(size.width), Int32(size.height))
    }

    deinit {
        currentTrack = nil
        ass_library_done(library)
        ass_renderer_done(renderer)
    }
}

extension AssImageRenderer: KSSubtitleProtocol {
    public func image(for time: TimeInterval, changed: inout Int32) -> (CGPoint, CGImage)? {
        let millisecond = Int64(time * 1000)
        guard let frame = ass_render_frame(renderer, currentTrack, millisecond, &changed) else {
            return nil
        }
        guard changed != 0 else {
            return nil
        }
        let images = frame.pointee.linkedImages()
        let boundingRect = imagesBoundingRect(images: images)
        var imagePipeline: ImagePipelineType.Type
//         图片少的话，用Accelerate性能会更好，耗时是0.005左右,而BlendImagePipeline就要0.04左右了
        if #available(iOS 16.0, tvOS 16.0, visionOS 1.0, macOS 13.0, macCatalyst 16.0, *), images.count <= 220 {
            imagePipeline = AccelerateImagePipeline.self
        } else {
            imagePipeline = BlendImagePipeline.self
        }
//        let start = CACurrentMediaTime()
        guard let image = imagePipeline.process(images: images, boundingRect: boundingRect) else {
            return nil
        }
//        print("image count: \(images.count) time:\(CACurrentMediaTime() - start)")
        return (boundingRect.origin, image)
    }

    public func search(for time: TimeInterval, size: CGSize) async -> [SubtitlePart] {
        setFrame(size: size)
        var changed = Int32(0)
        guard let processedImage = image(for: time, changed: &changed) else {
            if changed == 0 {
                return []
            } else {
                return [SubtitlePart(time, .infinity, "")]
            }
        }
        let part = SubtitlePart(time, .infinity, image: (processedImage.0, UIImage(cgImage: processedImage.1)))
        return [part]
    }
}

/// Pipeline that processed an `ASS_Image` into a ``ProcessedImage`` that can be drawn on the screen.
public protocol ImagePipelineType {
    static func process(images: [ASS_Image], boundingRect: CGRect) -> CGImage?
}

/// Find the bounding rect of all linked images.
///
/// - Parameters:
///   - images: Images list to find the bounding rect for.
///
/// - Returns: A `CGRect` containing all image rectangles.
private func imagesBoundingRect(images: [ASS_Image]) -> CGRect {
    let imagesRect = images.map(\.imageRect)
    guard let minX = imagesRect.map(\.minX).min(),
          let minY = imagesRect.map(\.minY).min(),
          let maxX = imagesRect.map(\.maxX).max(),
          let maxY = imagesRect.map(\.maxY).max() else { return .zero }

    return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
}
