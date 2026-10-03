import Foundation
import Testing
@testable import Revisit

struct FormattersTests {
    @Test func distance() {
        #expect(Formatters.distance(850) == "850 m")
        #expect(Formatters.distance(5210) == "5.21 km")
        #expect(Formatters.distance(10000) == "10.00 km")
    }

    @Test func duration() {
        #expect(Formatters.duration(1693) == "28:13")
        #expect(Formatters.duration(3723) == "1:02:03")
        #expect(Formatters.duration(59) == "0:59")
    }

    @Test func pace() {
        #expect(Formatters.pace(distance: 5000, duration: 1500, style: .minutesPerKilometer) == "5'00\" /km")
        #expect(Formatters.pace(distance: 5000, duration: 1620, style: .minutesPerKilometer) == "5'24\" /km")
        #expect(Formatters.pace(distance: 30000, duration: 3600, style: .kilometersPerHour) == "30.0 km/h")
        #expect(Formatters.pace(distance: 1500, duration: 1875, style: .minutesPer100Meters) == "2'05\" /100m")
        #expect(Formatters.pace(distance: 0, duration: 100, style: .minutesPerKilometer) == "—")
    }
}
