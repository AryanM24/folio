import FolioKit
import SwiftUI

/// Tiny hand-drawn previews of each kind of new file, for the "Start something" tiles.
/// They're drawings of paper and screens, so they keep paper colors in dark mode too.
struct Miniature: View {
    let kind: NewFile

    var body: some View {
        switch kind {
        case .document: MiniDocument()
        case .spreadsheet: MiniSheet()
        case .text: MiniCode()
        case .markdown: MiniMarkdown()
        case .pdf: MiniPDF()
        }
    }
}

private let ink = Color(hex: 0x27272A)
private let rule = Color(hex: 0xD4D4D8)
private let paperShadow = Color.black.opacity(0.14)

/// A white page with a soft drop shadow, the base of the paper miniatures.
private struct Page<Content: View>: View {
    var width: CGFloat = 52
    var height: CGFloat = 66
    @ViewBuilder var content: Content

    var body: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(.white)
            .frame(width: width, height: height)
            .overlay(alignment: .topLeading) { content.padding(8) }
            .shadow(color: paperShadow, radius: 2.5, y: 1)
    }
}

private struct Line: View {
    let width: CGFloat
    var color = rule
    var height: CGFloat = 2.5
    var body: some View { Capsule().fill(color).frame(width: width, height: height) }
}

private struct MiniDocument: View {
    var body: some View {
        Page {
            VStack(alignment: .leading, spacing: 4) {
                Line(width: 24, color: ink, height: 4)
                    .padding(.bottom, 2)
                ForEach([36, 33, 36, 20], id: \.self) { Line(width: CGFloat($0)) }
                Line(width: 30).padding(.top, 3)
                Line(width: 34)
            }
        }
    }
}

private struct MiniSheet: View {
    private let cols = 4
    private let rows = 5
    private let cell = CGSize(width: 16, height: 10)

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<rows, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(0..<cols, id: \.self) { col in
                        Rectangle()
                            .fill(row == 0 ? Color(hex: 0xF4F4F5) : .white)
                            .frame(width: cell.width, height: cell.height)
                            .overlay { Rectangle().strokeBorder(Color(hex: 0xE4E4E7), lineWidth: 0.5) }
                            .overlay(alignment: .leading) {
                                if row > 0, col != 2 || row != 2 {
                                    Line(width: CGFloat(4 + (row * 3 + col * 5) % 8), height: 2).padding(.leading, 3)
                                } else if row == 0 {
                                    Line(width: 7, color: Color(hex: 0xA1A1AA), height: 2).padding(.leading, 3)
                                }
                            }
                            .overlay {
                                if row == 2, col == 2 {
                                    Rectangle().fill(Hero.accent.opacity(0.12))
                                        .overlay { Rectangle().strokeBorder(Hero.accent, lineWidth: 1.5) }
                                }
                            }
                    }
                }
            }
        }
        .clipShape(.rect(cornerRadius: 3))
        .shadow(color: paperShadow, radius: 2.5, y: 1)
    }
}

private struct MiniCode: View {
    // One Dark-ish syntax colors: keyword, function, string, number, comment.
    private let lines: [(indent: CGFloat, parts: [(UInt32, CGFloat)])] = [
        (0, [(0xC678DD, 10), (0x61AFEF, 18)]),
        (6, [(0xE06C75, 8), (0xABB2BF, 6), (0x98C379, 16)]),
        (6, [(0xC678DD, 9), (0xD19A66, 8)]),
        (0, [(0xABB2BF, 4)]),
        (0, [(0x5C6370, 26)]),
    ]

    var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Color(hex: 0x1F1F23))
            .frame(width: 70, height: 54)
            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.1), lineWidth: 0.5) }
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 3) {
                        ForEach([0xFF5F57, 0xFEBC2E, 0x28C840] as [UInt32], id: \.self) {
                            Circle().fill(Color(hex: $0)).frame(width: 4, height: 4)
                        }
                    }
                    .padding(.bottom, 2)
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        HStack(spacing: 2.5) {
                            ForEach(Array(line.parts.enumerated()), id: \.offset) { _, part in
                                Line(width: part.1, color: Color(hex: part.0), height: 2.5)
                            }
                        }
                        .padding(.leading, line.indent)
                    }
                }
                .padding(7)
            }
            .shadow(color: paperShadow, radius: 2.5, y: 1)
    }
}

private struct MiniMarkdown: View {
    var body: some View {
        Page {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 3) {
                    Text("#").font(.system(size: 7, weight: .bold, design: .monospaced)).foregroundStyle(Hero.accent)
                    Line(width: 20, color: ink, height: 3.5)
                }
                ForEach([30, 24], id: \.self) { Line(width: CGFloat($0)) }
                ForEach([22, 26, 18], id: \.self) { width in
                    HStack(spacing: 3) {
                        Circle().fill(Color(hex: 0xA1A1AA)).frame(width: 3, height: 3)
                        Line(width: CGFloat(width))
                    }
                }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            Text("M↓")
                .font(.system(size: 6, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 3)
                .frame(height: 10)
                .background(ink, in: .rect(cornerRadius: 2))
                .offset(x: 6, y: -6)
        }
    }
}

private struct MiniPDF: View {
    var body: some View {
        Page {
            VStack(alignment: .leading, spacing: 4) {
                Line(width: 26, color: ink, height: 4).padding(.bottom, 2)
                Line(width: 36)
                Line(width: 32)
                    .background(Color(hex: 0xFDE047).opacity(0.75).frame(width: 38, height: 7).offset(x: 1))
                Line(width: 36)
                Line(width: 28)
                Line(width: 34)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            Text("PDF")
                .font(.system(size: 6, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 3)
                .frame(height: 10)
                .background(Color(hex: 0xE5484D), in: .rect(cornerRadius: 2))
                .offset(x: 6, y: -6)
        }
    }
}
