//
//  InsightsValues.swift
//  Aidoku
//
//  SUWA-13 F4 L10: the reading statistics, read together.
//

/// What the statistics screen shows, read in one context (§1.3 nº 25).
struct InsightsSnapshot: Sendable {
    var currentStreak: Int
    var longestStreak: Int
    var heatmap: HeatmapData
    var chart: [YearlyMonthData]
    var pagesTotal: Int
    var pagesMonth: Int
    var pagesYear: Int
    var seriesTotal: Int
    var seriesMonth: Int
    var seriesYear: Int
    var hoursTotal: Int
    var hoursMonth: Int
    var hoursYear: Int
}
