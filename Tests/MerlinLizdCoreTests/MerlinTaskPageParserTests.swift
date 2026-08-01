import Testing
@testable import MerlinLizdCore

@Suite("Merlin task parsing")
struct MerlinTaskPageParserTests {
    @Test("keeps only manual training and data processing runs")
    func keepsOnlyUserTasks() throws {
        let json = """
        {
          "total": 8,
          "list": [
            {
              "id": "run-running",
              "job_def_name": "train-running",
              "status": "RUNNING",
              "job_type": "Train",
              "trigger_mode": "MANUAL",
              "creation_time": "800",
              "completed_time": "0",
              "latest_trial_id": "389738351",
              "meta": {
                "caption": "platform-copy-name",
                "start_running_time": "750",
                "total_runtime_ms": "0",
                "job_run_params": {
                  "resource": {
                    "arnold_config": {
                      "clusterName": "federationgpu-hl",
                      "roles": [{
                        "name": "worker",
                        "gpu": 8,
                        "memory": 364544,
                        "num": 2,
                        "queueName": "must-not-be-persisted"
                      }]
                    }
                  }
                },
                "access_token": "must-not-be-persisted"
              }
            },
            {
              "id": "run-queued",
              "job_def_name": "data-queued",
              "status": "QUEUED",
              "job_type": "DataProcessing",
              "trigger_mode": "MANUAL",
              "creation_time": 700,
              "environment_variables": {"SECRET": "must-not-be-decoded"}
            },
            {
              "id": "run-failed",
              "job_def_name": "data-failed",
              "status": "FAILED",
              "job_type": "DataProcessing",
              "trigger_mode": "MANUAL",
              "creation_time": "600",
              "completed_time": "690",
              "meta": {
                "start_running_time": "620",
                "total_runtime_ms": "70"
              }
            },
            {
              "id": "run-stopped",
              "job_def_name": "train-stopped",
              "status": "STOPPED",
              "job_type": "Train",
              "trigger_mode": "MANUAL",
              "creation_time": "500"
            },
            {
              "id": "run-killed",
              "job_def_name": "train-killed",
              "status": "KILLED",
              "job_type": "Train",
              "trigger_mode": "MANUAL",
              "creation_time": "400"
            },
            {
              "id": "workspace-worker",
              "job_def_name": "worker",
              "status": "RUNNING",
              "job_type": "WorkspaceWorker",
              "trigger_mode": "FROM_API",
              "creation_time": "300"
            },
            {
              "id": "api-train",
              "job_def_name": "api-train",
              "status": "RUNNING",
              "job_type": "Train",
              "trigger_mode": "FROM_API",
              "creation_time": "200"
            },
            {
              "id": "future-state",
              "job_def_name": "future",
              "status": "FUTURE_STATE",
              "job_type": "Train",
              "trigger_mode": "MANUAL",
              "creation_time": "100"
            }
          ]
        }
        """

        let page = try MerlinTaskPageParser.parse(json)

        #expect(page.total == 8)
        #expect(page.itemCount == 8)
        #expect(page.runs.map(\.id) == [
            "run-running",
            "run-queued",
            "run-failed",
            "run-stopped",
            "run-killed",
        ])
        #expect(page.runs.map(\.lifecycle) == [
            .active,
            .active,
            .failed,
            .finished,
            .finished,
        ])
        #expect(page.runs[0].name == "platform-copy-name")
        #expect(page.runs[1].name == "data-queued")
        #expect(page.runs[0].status == .running)
        #expect(page.runs[0].startedAtMilliseconds == 750)
        #expect(page.runs[0].completedAtMilliseconds == nil)
        #expect(page.runs[0].totalRuntimeMilliseconds == nil)
        #expect(page.runs[0].trialID == "389738351")
        #expect(page.runs[0].metricRoleName == "worker")
        #expect(page.runs[0].clusterName == "federationgpu-hl")
        #expect(page.runs[0].clusterShortCode == "hl")
        #expect(page.runs[0].allocatedGPUCount == 16)
        #expect(
            page.runs[0].allocatedMemoryBytes
                == UInt64(364_544 * 2) * 1_048_576
        )
        #expect(page.runs[2].status == .failed)
        #expect(page.runs[2].startedAtMilliseconds == 620)
        #expect(page.runs[2].completedAtMilliseconds == 690)
        #expect(page.runs[2].totalRuntimeMilliseconds == 70)
        #expect(page.runs[0].createdAtMilliseconds == 800)
        #expect(page.runs[1].createdAtMilliseconds == 700)

        let snapshot = MerlinTaskSnapshot.presenting(
            page.runs,
            refreshedAt: taskTestDate(1)
        )
        let encoded = try encodedTaskSnapshot(snapshot)
        #expect(!encoded.contains("must-not-be-persisted"))
        #expect(!encoded.contains("must-not-be-decoded"))
        #expect(encoded.contains("389738351"))
    }

    @Test("rejects malformed responses")
    func rejectsMalformedResponses() {
        #expect(throws: MerlinTaskPageParserError.malformedResponse) {
            try MerlinTaskPageParser.parse("{not-json")
        }
    }
}

@Suite("Merlin task presentation")
struct MerlinTaskSnapshotTests {
    @Test("computes a running task duration from its platform start time")
    func computesLiveRuntime() {
        let run = MerlinTaskRun(
            id: "live",
            name: "live",
            status: .running,
            createdAtMilliseconds: 500,
            startedAtMilliseconds: 1_000
        )

        #expect(run.runtimeSeconds(at: taskTestDate(6.5)) == 5.5)
    }

    @Test("keeps a terminal task duration fixed at the platform runtime")
    func keepsFinalRuntime() {
        let run = MerlinTaskRun(
            id: "done",
            name: "done",
            status: .done,
            createdAtMilliseconds: 500,
            startedAtMilliseconds: 1_000,
            completedAtMilliseconds: 8_000,
            totalRuntimeMilliseconds: 7_000
        )

        #expect(run.runtimeSeconds(at: taskTestDate(100)) == 7)
    }

    @Test("keeps every active run and caps terminal groups")
    func appliesLifecycleLimits() {
        let active = (0..<25).map {
            run(id: "active-\($0)", lifecycle: .active, time: Int64($0))
        }
        let failed = (0..<25).map {
            run(id: "failed-\($0)", lifecycle: .failed, time: Int64($0))
        }
        let finished = (0..<25).map {
            run(id: "finished-\($0)", lifecycle: .finished, time: Int64($0))
        }

        let snapshot = MerlinTaskSnapshot.presenting(
            active + failed + finished,
            refreshedAt: taskTestDate(1),
            historyLimit: 20
        )

        #expect(snapshot.runs(in: .active).count == 25)
        #expect(snapshot.runs(in: .failed).count == 20)
        #expect(snapshot.runs(in: .finished).count == 20)
        #expect(snapshot.runs(in: .active).first?.id == "active-24")
        #expect(snapshot.runs(in: .failed).last?.id == "failed-5")
        #expect(snapshot.runs(in: .finished).last?.id == "finished-5")
    }

    private func run(
        id: String,
        lifecycle: MerlinTaskLifecycle,
        time: Int64
    ) -> MerlinTaskRun {
        let status: MerlinTaskStatus
        switch lifecycle {
        case .active:
            status = .running
        case .failed:
            status = .failed
        case .finished:
            status = .done
        }
        return MerlinTaskRun(
            id: id,
            name: id,
            status: status,
            createdAtMilliseconds: time
        )
    }
}
