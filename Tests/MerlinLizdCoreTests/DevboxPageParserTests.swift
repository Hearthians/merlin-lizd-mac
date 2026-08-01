import Testing
@testable import MerlinLizdCore

@Suite("Devbox inventory parsing")
struct DevboxPageParserTests {
    @Test("decodes the safe inventory fields and validated SSH destination")
    func decodesSafeFields() throws {
        let json = """
        {
          "ResponseBase": {"code": 0, "code_name": "", "message": "success", "meta": {}},
          "data": [
            {
              "sid": "dbx_135679",
              "name": "wt_hl",
              "status": "future_state",
              "cpu_cores": 8,
              "memory_bytes": 34359738368,
              "disk_bytes": 137438953472,
              "worker_num": 4,
              "rootfs_type": "nfs",
              "region": "cn",
              "cluster": {"name": "candy-yg", "dc": "yg", "id": 8},
              "access_role": "OWNER",
              "created_at": "2026-07-08T04:08:15Z",
              "updated_at": "2026-07-11T08:00:00Z",
              "environment_variables": {"SECRET_TOKEN": "must-not-be-decoded"},
              "ssh_proxy_cmd": "135679.lizhuodong.ws@merlin-ssh-proxy-cn.byted.org"
            }
          ],
          "pagination": {"total": 1, "page_size": 100, "next_page_token": "opaque-next"}
        }
        """

        let page = try DevboxPageParser.parse(json)

        #expect(page.devboxes.count == 1)
        #expect(page.devboxes[0].sid == "dbx_135679")
        #expect(page.devboxes[0].name == "wt_hl")
        #expect(page.devboxes[0].status.rawValue == "future_state")
        #expect(page.devboxes[0].cpuCores == 8)
        #expect(page.devboxes[0].memoryBytes == 34_359_738_368)
        #expect(page.devboxes[0].diskBytes == 137_438_953_472)
        #expect(page.devboxes[0].workerCount == 4)
        #expect(page.devboxes[0].cluster == DevboxCluster(
            id: 8,
            name: "candy-yg",
            dataCenter: "yg"
        ))
        #expect(page.devboxes[0].accessRole == "OWNER")
        #expect(page.devboxes[0].sshProxyDestination ==
            "135679.lizhuodong.ws@merlin-ssh-proxy-cn.byted.org")
        #expect(page.nextPageToken == "opaque-next")
    }

    @Test("rejects an SSH destination that does not match the Devbox SID")
    func rejectsMismatchedSSHDestination() throws {
        let json = """
        {
          "ResponseBase": {"code": 0, "message": "success"},
          "data": [{
            "sid": "dbx_140542",
            "name": "hl_gpu",
            "status": "running",
            "ssh_proxy_cmd": "999999.lizhuodong.ws@merlin-ssh-proxy-cn.byted.org"
          }],
          "pagination": {"page_size": 100}
        }
        """

        let devbox = try #require(DevboxPageParser.parse(json).devboxes.first)

        #expect(devbox.sshProxyDestination == nil)
    }

    @Test("normalizes lifecycle casing at the decode boundary")
    func normalizesLifecycleCasing() throws {
        let json = """
        {
          "ResponseBase": {"code": 0, "message": "success"},
          "data": [{"sid": "dbx_1", "name": "one", "status": " RUNNING "}],
          "pagination": {"page_size": 100}
        }
        """

        let devbox = try #require(DevboxPageParser.parse(json).devboxes.first)

        #expect(devbox.status == .running)
        #expect(devbox.status.isRunning)
    }

    @Test("keeps the Devbox usable when cluster metadata is partial")
    func acceptsPartialClusterMetadata() throws {
        let json = """
        {
          "ResponseBase": {"code": 0, "message": "success"},
          "data": [{
            "sid": "dbx_140542",
            "name": "hl_gpu",
            "status": "running",
            "cluster": {"dc": "hl", "id": 6}
          }],
          "pagination": {"page_size": 100}
        }
        """

        let devbox = try #require(DevboxPageParser.parse(json).devboxes.first)

        #expect(devbox.cluster?.name == nil)
        #expect(devbox.cluster?.dataCenter == "hl")
        #expect(devbox.cluster?.id == 6)
    }
}
