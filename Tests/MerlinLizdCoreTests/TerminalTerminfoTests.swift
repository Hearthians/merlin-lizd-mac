import Testing
@testable import MerlinLizdCore

@Suite("Terminal terminfo routing")
struct TerminalTerminfoTests {
    @Test("uses broadly supported xterm for a Devbox terminal")
    func usesXtermForDevbox() {
        let target = TerminalTarget.devbox(
            sid: "dbx_135679",
            name: "wt_hl",
            alias: "hl_gpu_2"
        )

        #expect(TerminalTerminfo.term(for: target) == "xterm")
    }

    @Test("uses broadly supported xterm for a Worker terminal")
    func usesXtermForWorker() {
        let target = TerminalTarget.worker(
            devboxSID: "dbx_135679",
            devboxName: "wt_hl",
            alias: "hl_gpu_2",
            workerID: "4004694"
        )

        #expect(TerminalTerminfo.term(for: target) == "xterm")
    }

    @Test("keeps the richer terminfo for a local terminal")
    func keepsXterm256ColorForLocalTerminal() {
        #expect(TerminalTerminfo.term(for: .local) == "xterm-256color")
    }
}
