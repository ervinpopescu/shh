import XCTest
@testable import ShhCore

final class ServerTelemetryTests: XCTestCase {

    // MARK: - 1. Helper Calculations & Formatting Tests

    func testMemoryUsagePercentageCalculation() {
        let telemetry = ServerTelemetry(
            memoryUsedBytes: 1_073_741_824, // 1 GB
            memoryTotalBytes: 4_294_967_296 // 4 GB
        )
        XCTAssertEqual(telemetry.memoryUsagePercentage, 25.0)

        let nilUsed = ServerTelemetry(memoryUsedBytes: nil, memoryTotalBytes: 4_294_967_296)
        XCTAssertNil(nilUsed.memoryUsagePercentage)

        let nilTotal = ServerTelemetry(memoryUsedBytes: 1_073_741_824, memoryTotalBytes: nil)
        XCTAssertNil(nilTotal.memoryUsagePercentage)

        let zeroTotal = ServerTelemetry(memoryUsedBytes: 100, memoryTotalBytes: 0)
        XCTAssertNil(zeroTotal.memoryUsagePercentage)
    }

    func testFormattedUptime() {
        // Days and hours
        let threeDaysFourHours = ServerTelemetry(uptimeSeconds: (3 * 86400) + (4 * 3600))
        XCTAssertEqual(threeDaysFourHours.formattedUptime, "3d 4h")

        // Hours and minutes
        let twelveHoursThirtyMin = ServerTelemetry(uptimeSeconds: (12 * 3600) + (30 * 60))
        XCTAssertEqual(twelveHoursThirtyMin.formattedUptime, "12h 30m")

        // Minutes only
        let fortyFiveMin = ServerTelemetry(uptimeSeconds: 45 * 60)
        XCTAssertEqual(fortyFiveMin.formattedUptime, "45m")

        // Seconds only
        let thirtySec = ServerTelemetry(uptimeSeconds: 30)
        XCTAssertEqual(thirtySec.formattedUptime, "30s")

        // Nil uptime
        let nilUptime = ServerTelemetry(uptimeSeconds: nil)
        XCTAssertEqual(nilUptime.formattedUptime, "-")

        // Negative uptime
        let negativeUptime = ServerTelemetry(uptimeSeconds: -10)
        XCTAssertEqual(negativeUptime.formattedUptime, "-")
    }

    func testFormattedMemory() {
        // Gigabytes formatting (e.g. 1.2 / 4.0 GB (30%))
        let usedBytes: Int64 = Int64(1.2 * 1024 * 1024 * 1024)
        let totalBytes: Int64 = Int64(4.0 * 1024 * 1024 * 1024)
        let telemetry = ServerTelemetry(memoryUsedBytes: usedBytes, memoryTotalBytes: totalBytes)
        XCTAssertEqual(telemetry.formattedMemory, "1.2 / 4.0 GB (30%)")

        // Megabytes formatting
        let usedMB: Int64 = 256 * 1024 * 1024
        let totalMB: Int64 = 512 * 1024 * 1024
        let mbTelemetry = ServerTelemetry(memoryUsedBytes: usedMB, memoryTotalBytes: totalMB)
        XCTAssertEqual(mbTelemetry.formattedMemory, "256 / 512 MB (50%)")

        // Nil or zero values
        let nilMemory = ServerTelemetry(memoryUsedBytes: nil, memoryTotalBytes: nil)
        XCTAssertEqual(nilMemory.formattedMemory, "-")
    }

    func testCodableRoundTrip() throws {
        let original = ServerTelemetry(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 1700000000),
            cpuUsagePercentage: 42.5,
            memoryUsedBytes: 2_147_483_648,
            memoryTotalBytes: 8_589_934_592,
            loadAverage: (0.45, 0.32, 0.18),
            uptimeSeconds: 123456
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(ServerTelemetry.self, from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.timestamp, original.timestamp)
        XCTAssertEqual(decoded.cpuUsagePercentage, original.cpuUsagePercentage)
        XCTAssertEqual(decoded.memoryUsedBytes, original.memoryUsedBytes)
        XCTAssertEqual(decoded.memoryTotalBytes, original.memoryTotalBytes)
        XCTAssertEqual(decoded.loadAverage?.0, original.loadAverage?.0)
        XCTAssertEqual(decoded.loadAverage?.1, original.loadAverage?.1)
        XCTAssertEqual(decoded.loadAverage?.2, original.loadAverage?.2)
        XCTAssertEqual(decoded.uptimeSeconds, original.uptimeSeconds)
        XCTAssertEqual(decoded, original)
    }

    func testHashableAndEquatable() {
        let id = UUID()
        let date = Date(timeIntervalSince1970: 1700000000)
        let t1 = ServerTelemetry(id: id, timestamp: date, cpuUsagePercentage: 15.0, loadAverage: (1.0, 2.0, 3.0))
        let t2 = ServerTelemetry(id: id, timestamp: date, cpuUsagePercentage: 15.0, loadAverage: (1.0, 2.0, 3.0))
        let t3 = ServerTelemetry(id: id, timestamp: date, cpuUsagePercentage: 20.0, loadAverage: (1.0, 2.0, 3.0))

        XCTAssertEqual(t1, t2)
        XCTAssertNotEqual(t1, t3)

        var set: Set<ServerTelemetry> = []
        set.insert(t1)
        set.insert(t2)
        XCTAssertEqual(set.count, 1)
        set.insert(t3)
        XCTAssertEqual(set.count, 2)
    }

    // MARK: - 2. Linux /proc Parsers

    func testParseLinuxProcLoadAvg() {
        let parser = ServerTelemetryParser()
        let loadavgSample = "0.08 0.03 0.01 1/245 12345"
        let telemetry = parser.parse(loadavgSample)

        XCTAssertNotNil(telemetry.loadAverage)
        XCTAssertEqual(telemetry.loadAverage?.0 ?? 0, 0.08, accuracy: 0.001)
        XCTAssertEqual(telemetry.loadAverage?.1 ?? 0, 0.03, accuracy: 0.001)
        XCTAssertEqual(telemetry.loadAverage?.2 ?? 0, 0.01, accuracy: 0.001)
    }

    func testParseLinuxProcMeminfoWithAvailable() {
        let parser = ServerTelemetryParser()
        let meminfoSample = """
        MemTotal:       16384000 kB
        MemFree:         4096000 kB
        MemAvailable:    8192000 kB
        Buffers:          500000 kB
        Cached:          2000000 kB
        """
        let telemetry = parser.parse(meminfoSample)

        let expectedTotal: Int64 = 16384000 * 1024
        let expectedUsed: Int64 = (16384000 - 8192000) * 1024
        XCTAssertEqual(telemetry.memoryTotalBytes, expectedTotal)
        XCTAssertEqual(telemetry.memoryUsedBytes, expectedUsed)
        XCTAssertEqual(telemetry.memoryUsagePercentage ?? 0, 50.0, accuracy: 0.01)
    }

    func testParseLinuxProcMeminfoWithoutAvailableFallback() {
        let parser = ServerTelemetryParser()
        let meminfoSample = """
        MemTotal:       1000000 kB
        MemFree:         200000 kB
        Buffers:         100000 kB
        Cached:          300000 kB
        """
        let telemetry = parser.parse(meminfoSample)

        // Available = 200000 + 100000 + 300000 = 600000 kB
        // Used = 1000000 - 600000 = 400000 kB
        let expectedTotal: Int64 = 1000000 * 1024
        let expectedUsed: Int64 = 400000 * 1024
        XCTAssertEqual(telemetry.memoryTotalBytes, expectedTotal)
        XCTAssertEqual(telemetry.memoryUsedBytes, expectedUsed)
        XCTAssertEqual(telemetry.memoryUsagePercentage ?? 0, 40.0, accuracy: 0.01)
    }

    func testParseLinuxProcStatCPU() {
        let parser = ServerTelemetryParser()
        // cpu user nice system idle iowait irq softirq steal
        // busy = 200 + 50 + 150 = 400
        // idle = 600 + 0 = 600
        // total = 1000 -> 40.0%
        let statSample = """
        cpu  200 50 150 600 0 0 0 0 0 0
        cpu0 100 25 75 300 0 0 0 0 0 0
        cpu1 100 25 75 300 0 0 0 0 0 0
        intr 1234567
        """
        let telemetry = parser.parse(statSample)

        XCTAssertNotNil(telemetry.cpuUsagePercentage)
        XCTAssertEqual(telemetry.cpuUsagePercentage ?? 0, 40.0, accuracy: 0.01)
    }

    func testParseLinuxProcUptime() {
        let parser = ServerTelemetryParser()
        let uptimeSample = "354120.45 1234567.89"
        let telemetry = parser.parse(uptimeSample)

        XCTAssertEqual(telemetry.uptimeSeconds, 354120.45)
    }

    func testParseCombinedLinuxTelemetryOutput() {
        let parser = ServerTelemetryParser()
        let scriptOutput = """
        0.25 0.18 0.12 2/180 5432
        MemTotal:        4194304 kB
        MemFree:          524288 kB
        MemAvailable:    2097152 kB
        Buffers:          104857 kB
        Cached:          1048576 kB
        cpu  500 0 500 1000 0 0 0 0
         14:05:20 up 3 days,  4:15,  2 users,  load average: 0.25, 0.18, 0.12
        """
        let telemetry = parser.parse(scriptOutput)

        XCTAssertEqual(telemetry.loadAverage?.0 ?? 0, 0.25, accuracy: 0.001)
        XCTAssertEqual(telemetry.loadAverage?.1 ?? 0, 0.18, accuracy: 0.001)
        XCTAssertEqual(telemetry.loadAverage?.2 ?? 0, 0.12, accuracy: 0.001)

        XCTAssertEqual(telemetry.memoryTotalBytes, 4194304 * 1024)
        XCTAssertEqual(telemetry.memoryUsedBytes, (4194304 - 2097152) * 1024)
        XCTAssertEqual(telemetry.memoryUsagePercentage ?? 0, 50.0, accuracy: 0.01)

        XCTAssertEqual(telemetry.cpuUsagePercentage ?? 0, 50.0, accuracy: 0.01)
        let expectedUptime: TimeInterval = 274_500.0 // 3d 4h 15m
        XCTAssertEqual(telemetry.uptimeSeconds, expectedUptime)
        XCTAssertEqual(telemetry.formattedUptime, "3d 4h")
    }

    // MARK: - 3. macOS / BSD Fallback Parsers

    func testParseMacOSVmStatAndUptime() {
        let parser = ServerTelemetryParser()
        let vmStatOutput = """
        Mach Virtual Memory Statistics: (page size of 16384 bytes)
        Pages free:                               10000.
        Pages active:                             20000.
        Pages inactive:                           10000.
        Pages speculative:                         2000.
        Pages throttled:                              0.
        Pages wired down:                         10000.
        Pages purgeable:                           1000.
        "Translation faults":                  12345678.
        Pages occupied by compressor:             10000.
        """
        let uptimeOutput = "16:45  up 12 days,  3:40, 4 users, load averages: 1.85 2.10 1.95"

        let telemetry = parser.parseMacOS(vmStat: vmStatOutput, uptime: uptimeOutput)

        // total pages = free(10000) + active(20000) + inactive(10000) + spec(2000) + wired(10000) + comp(10000) = 62000
        // total bytes = 62000 * 16384 = 1015808000 bytes
        // used pages = active(20000) + wired(10000) + comp(10000) = 40000
        // used bytes = 40000 * 16384 = 655360000 bytes
        XCTAssertEqual(telemetry.memoryTotalBytes, 62000 * 16384)
        XCTAssertEqual(telemetry.memoryUsedBytes, 40000 * 16384)

        XCTAssertEqual(telemetry.loadAverage?.0 ?? 0, 1.85, accuracy: 0.001)
        XCTAssertEqual(telemetry.loadAverage?.1 ?? 0, 2.10, accuracy: 0.001)
        XCTAssertEqual(telemetry.loadAverage?.2 ?? 0, 1.95, accuracy: 0.001)

        let expectedUptime = (12 * 86400) + (3 * 3600) + (40 * 60)
        XCTAssertEqual(telemetry.uptimeSeconds, Double(expectedUptime))
        XCTAssertEqual(telemetry.formattedUptime, "12d 3h")
    }

    func testUptimeCommandVariations() {
        let parser = ServerTelemetryParser()

        // Variation 1: minutes only
        let t1 = parser.parse(" 21:40:02 up 45 min,  1 user,  load average: 0.00, 0.01, 0.00")
        XCTAssertEqual(t1.uptimeSeconds, 45 * 60)
        XCTAssertEqual(t1.formattedUptime, "45m")

        // Variation 2: hours and minutes
        let t2 = parser.parse(" 12:34:56 up 2:30,  1 user,  load average: 1.02, 0.55, 0.32")
        XCTAssertEqual(t2.uptimeSeconds, (2 * 3600) + (30 * 60))
        XCTAssertEqual(t2.formattedUptime, "2h 30m")

        // Variation 3: days and minutes
        let t3 = parser.parse(" 10:15:00 up 10 days, 23 min, 1 user, load average: 0.50, 0.40, 0.30")
        XCTAssertEqual(t3.uptimeSeconds, (10 * 86400) + (23 * 60))
        XCTAssertEqual(t3.formattedUptime, "10d 0h")
    }

    // MARK: - 4. Edge Cases & Resilience

    func testEmptyAndGarbageInputDoesNotCrash() {
        let parser = ServerTelemetryParser()

        let empty = parser.parse("")
        XCTAssertNil(empty.loadAverage)
        XCTAssertNil(empty.memoryTotalBytes)
        XCTAssertNil(empty.memoryUsedBytes)
        XCTAssertNil(empty.cpuUsagePercentage)
        XCTAssertNil(empty.uptimeSeconds)

        let garbage = parser.parse("some random error occurred: permission denied\ncommand not found")
        XCTAssertNil(garbage.loadAverage)
        XCTAssertNil(garbage.memoryTotalBytes)
        XCTAssertNil(garbage.memoryUsedBytes)
        XCTAssertNil(garbage.cpuUsagePercentage)
        XCTAssertNil(garbage.uptimeSeconds)
    }

    func testPartialMeminfoWithoutTotalReturnsNil() {
        let parser = ServerTelemetryParser()
        let partial = """
        MemFree:         4096000 kB
        MemAvailable:    8192000 kB
        """
        let telemetry = parser.parse(partial)
        XCTAssertNil(telemetry.memoryTotalBytes)
        XCTAssertNil(telemetry.memoryUsedBytes)
    }

    func testPartialStatWithoutValidTokensReturnsNil() {
        let parser = ServerTelemetryParser()
        let invalidCpu = "cpu  abc def ghi jkl"
        let telemetry = parser.parse(invalidCpu)
        XCTAssertNil(telemetry.cpuUsagePercentage)
    }

    // MARK: - 5. CommandPolicy Integration

    func testCommandPolicyValidatesSafeTelemetryScript() {
        let script = "cat /proc/loadavg 2>/dev/null; cat /proc/meminfo 2>/dev/null; uptime 2>/dev/null"
        XCTAssertEqual(CommandPolicy.validate(script), .safe)
        XCTAssertEqual(CommandPolicy().validate(script), .safe)
        XCTAssertEqual(CommandPolicy().classify(script), .safe)
    }
}
