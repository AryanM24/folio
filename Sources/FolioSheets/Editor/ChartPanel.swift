import Charts
import FolioKit
import SwiftUI

/// Series extracted from a range: the first column is categories when it holds text,
/// the first row is series names when it holds text; every other column is a series.
nonisolated struct ChartData: Equatable {
    struct Point: Identifiable, Equatable {
        let id: Int
        let category: String
        let series: String
        let value: Double
    }

    var points: [Point]
    var seriesNames: [String]

    static let maxPoints = 2_000

    init(range: CellRange, value: (CellRef) -> CellValue) {
        func isText(_ v: CellValue) -> Bool { if case .text = v { true } else { false } }
        let firstRow = range.cols.map { value(CellRef(row: range.start.row, col: $0)) }
        let hasHeader = firstRow.dropFirst().contains(where: isText) || (range.colCount == 1 && isText(firstRow[0]))
        let dataRows = hasHeader ? (range.start.row + 1)...max(range.start.row + 1, range.end.row) : range.rows
        let firstCol = dataRows.map { value(CellRef(row: $0, col: range.start.col)) }
        let hasCategories = range.colCount > 1 && firstCol.contains(where: isText)
        let seriesCols = hasCategories ? Array(range.cols.dropFirst()) : Array(range.cols)
        seriesNames = seriesCols.map { c in
            let header = hasHeader ? value(CellRef(row: range.start.row, col: c)) : .empty
            if case .text(let s) = header, !s.isEmpty { return s }
            return CellRef.columnName(c)
        }
        var out: [Point] = []
        outer: for (i, r) in dataRows.enumerated() {
            let category: String
            if hasCategories, case .text(let s) = firstCol[i] {
                category = s
            } else if hasCategories {
                category = (try? firstCol[i].asText().get()) ?? String(r + 1)
            } else {
                category = String(r + 1)
            }
            for (k, c) in seriesCols.enumerated() {
                guard case .number(let n) = value(CellRef(row: r, col: c)) else { continue }
                out.append(Point(id: out.count, category: category, series: seriesNames[k], value: n))
                if out.count >= ChartData.maxPoints { break outer }
            }
        }
        points = out
    }
}

/// View-only chart of a range, beside the grid. Not saved with the file.
struct ChartPanel: View {
    let controller: SheetController
    let spec: ChartSpec

    var body: some View {
        let data = chartData
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Chart").font(.system(size: 13, weight: .semibold)).foregroundStyle(Hero.foreground)
                Text(spec.range.a1).font(.system(size: 12)).monospacedDigit().foregroundStyle(Hero.muted)
                Spacer()
                Button {
                    controller.insertChart()
                } label: {
                    Label("Use Selection", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.hero(.ghost, size: .sm, iconOnly: true))
                .help("Chart the current selection")
                Button {
                    controller.chart = nil
                } label: {
                    Label("Close Chart", systemImage: "xmark")
                }
                .buttonStyle(.hero(.ghost, size: .sm, iconOnly: true))
                .help("Close")
            }
            HeroTabs(ChartSpec.Kind.allCases.map { ($0, $0.title, $0.symbol) }, selection: kindBinding)
            if data.points.isEmpty {
                ContentUnavailableView(
                    "No numbers to chart", systemImage: "chart.bar",
                    description: Text("Select cells that contain numbers, then choose Insert Chart.")
                )
                .frame(maxHeight: .infinity)
            } else {
                chart(data)
                    .frame(maxHeight: .infinity)
                    .accessibilityLabel("\(spec.kind.title) chart of \(spec.range.a1)")
            }
            Text("Charts are a live view of your data and aren't saved in the file.")
                .font(.system(size: 11))
                .foregroundStyle(Hero.muted)
        }
        .padding(16)
        .background(Hero.surface)
        .overlay(alignment: .leading) { Rectangle().fill(Hero.separator).frame(width: 1) }
    }

    private var chartData: ChartData {
        _ = controller.revision
        let doc = controller.document
        return ChartData(range: spec.range) { doc.value(at: $0) }
    }

    private var kindBinding: Binding<ChartSpec.Kind> {
        Binding(get: { spec.kind }, set: { controller.chart?.kind = $0 })
    }

    /// Accent first, then the other Hero status colours.
    private static let palette: [Color] = [Hero.accent, Hero.success, Hero.warning, Hero.danger, Color(hex: 0x9353D3), Hero.muted]

    @ViewBuilder
    private func chart(_ data: ChartData) -> some View {
        let multi = data.seriesNames.count > 1
        // A pie shows one series: the first.
        let points = spec.kind == .pie ? data.points.filter { $0.series == data.seriesNames.first } : data.points
        Chart(points) { p in
            switch spec.kind {
            case .bar:
                BarMark(x: .value("Category", p.category), y: .value("Value", p.value))
                    .foregroundStyle(by: .value("Series", p.series))
                    .position(by: .value("Series", p.series))
                    .cornerRadius(Hero.Radius.sm)
            case .line:
                LineMark(x: .value("Category", p.category), y: .value("Value", p.value))
                    .foregroundStyle(by: .value("Series", p.series))
                    .interpolationMethod(.monotone)
                PointMark(x: .value("Category", p.category), y: .value("Value", p.value))
                    .foregroundStyle(by: .value("Series", p.series))
                    .symbolSize(20)
            case .area:
                AreaMark(x: .value("Category", p.category), y: .value("Value", p.value))
                    .foregroundStyle(by: .value("Series", p.series))
                    .opacity(0.8)
            case .pie:
                SectorMark(angle: .value("Value", max(0, p.value)), innerRadius: .ratio(0.55), angularInset: 1.5)
                    .foregroundStyle(by: .value("Category", p.category))
                    .cornerRadius(Hero.Radius.sm)
            }
        }
        .chartForegroundStyleScale(range: Self.palette)
        .chartLegend(multi || spec.kind == .pie ? .visible : .hidden)
    }
}
