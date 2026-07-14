import Testing
@testable import MerlinLizdCore

@Suite("tmux surfaces")
struct TmuxSurfaceTests {
    @Test("accepts only typed tmux window and pane IDs")
    func validatesTmuxSurfaceIdentifiers() {
        #expect(MerlinIdentifierValidator.isTmuxWindowID("@0"))
        #expect(MerlinIdentifierValidator.isTmuxWindowID("@123"))
        #expect(!MerlinIdentifierValidator.isTmuxWindowID("123"))
        #expect(!MerlinIdentifierValidator.isTmuxWindowID("@"))
        #expect(!MerlinIdentifierValidator.isTmuxWindowID("@12x"))
        #expect(!MerlinIdentifierValidator.isTmuxWindowID("@12;id"))

        #expect(MerlinIdentifierValidator.isTmuxPaneID("%0"))
        #expect(MerlinIdentifierValidator.isTmuxPaneID("%456"))
        #expect(!MerlinIdentifierValidator.isTmuxPaneID("456"))
        #expect(!MerlinIdentifierValidator.isTmuxPaneID("%"))
        #expect(!MerlinIdentifierValidator.isTmuxPaneID("%45x"))
        #expect(!MerlinIdentifierValidator.isTmuxPaneID("%45;id"))

        #expect(MerlinIdentifierValidator.isTmuxWindowIndex(0))
        #expect(MerlinIdentifierValidator.isTmuxWindowIndex(Int.max))
        #expect(!MerlinIdentifierValidator.isTmuxWindowIndex(-1))
    }

    @Test("parses the fixed current surface output")
    func parsesCurrentSurface() {
        #expect(TmuxSurfaceParser.parse(
            "$3,100,@12,%34,zsh\n"
        ) == TmuxSurface(
            sessionIdentity: TmuxSessionIdentity(
                serverSessionID: "$3", createdAtEpoch: 100
            ),
            windowID: "@12",
            paneID: "%34",
            currentCommand: "zsh"
        ))
        #expect(TmuxSurfaceParser.parse(
            "$3,100,@12,%34,python,worker.py\n"
        )?.currentCommand == "python,worker.py")
    }

    @Test("rejects malformed or untyped current surface output")
    func rejectsMalformedCurrentSurface() {
        let malformed = [
            "",
            "$3,100,@12,%34",
            "$x,100,@12,%34,zsh",
            "$3,-1,@12,%34,zsh",
            "$3,100,12,%34,zsh",
            "$3,100,@12,34,zsh",
            "$3,100,@12,%34,zsh\n$3,100,@12,%35,bash",
        ]

        for value in malformed {
            #expect(TmuxSurfaceParser.parse(value) == nil)
        }
    }

    @Test("parses only fixed typed split output")
    func parsesTemporaryPaneLocation() {
        #expect(TmuxSurfaceParser.parsePaneLocation("@12,%34\n") ==
            TmuxPaneLocation(windowID: "@12", paneID: "%34"))
        #expect(TmuxSurfaceParser.parsePaneLocation("@12,%34,extra") == nil)
        #expect(TmuxSurfaceParser.parsePaneLocation("12,%34") == nil)
        #expect(TmuxSurfaceParser.parsePaneLocation("@12,34") == nil)
    }

}
