import Testing
@testable import MerlinLizdCore

@Suite("Worker list parsing")
struct WorkerListParserTests {
    @Test("parses workers when GPU type or Pod IP columns are empty")
    func parsesSparseColumns() throws {
        let output = """
        warning: mlx auto-upgrade was skipped in a non-interactive shell
        id        cpu    mem    gpu    gpuType     podIP                                   port   createdAt            webshell
        3966762   20     225    1      NVIDIA-H20                                          9000   2026-07-09T04:49:39  https://workspace.byted.org/api/v1/workers/3966762/webshell/
        3960209   100    240    0                  fdbd:dc02:2b:84e::37                    9221   2026-07-08T05:20:59  https://workspace.byted.org/api/v1/workers/3960209/webshell/
        """

        let workers = try WorkerListParser.parse(output)

        #expect(workers.count == 2)
        #expect(workers[0].id == "3966762")
        #expect(workers[0].cpuCores == 20)
        #expect(workers[0].memoryGiB == 225)
        #expect(workers[0].gpuCount == 1)
        #expect(workers[0].gpuType == "NVIDIA-H20")
        #expect(workers[0].podIP == nil)
        #expect(workers[0].port == 9000)
        #expect(workers[1].id == "3960209")
        #expect(workers[1].gpuCount == 0)
        #expect(workers[1].gpuType == nil)
        #expect(workers[1].podIP == "fdbd:dc02:2b:84e::37")
        #expect(workers[1].port == 9221)
    }

    @Test("uses table column boundaries when a GPU type contains spaces")
    func parsesGPUTypeContainingSpaces() throws {
        let output = """
        id        cpu    mem    gpu    gpuType     podIP                                   port   createdAt            webshell
        9876543   32     128    1      NVIDIA H100                                         9443   2026-07-11T12:30:00  https://workspace.invalid/worker/
        """

        let workers = try WorkerListParser.parse(output)

        #expect(workers.count == 1)
        #expect(workers[0].gpuType == "NVIDIA H100")
        #expect(workers[0].podIP == nil)
        #expect(workers[0].port == 9443)
    }

    @Test("does not report zero workers when the table header is missing")
    func rejectsMissingHeader() {
        let output = """
        warning: remote command changed its output format
        3966762   20   225   1   NVIDIA-H20   9000   2026-07-09T04:49:39   https://example.invalid/
        """

        #expect(throws: WorkerListParserError.missingHeader) {
            try WorkerListParser.parse(output)
        }
    }

    @Test("rejects a data-looking row that no longer matches the table columns")
    func rejectsMalformedWorkerRow() {
        let output = """
        id        cpu    mem    gpu    gpuType     podIP                                   port   createdAt            webshell
        3966762   invalid-worker-row
        """

        #expect(throws: WorkerListParserError.malformedRow) {
            try WorkerListParser.parse(output)
        }
    }
}
