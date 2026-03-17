defmodule AlgedoniaWeb.Api.TicketControllerTest do
  use AlgedoniaWeb.ConnCase, async: true

  import Algedonia.Factory

  setup %{workspace: workspace, user: user} do
    token = Phoenix.Token.sign(AlgedoniaWeb.Endpoint, "daemon_auth", %{user_id: user.id})

    conn =
      Phoenix.ConnTest.build_conn()
      |> put_req_header("authorization", "Bearer #{token}")
      |> put_req_header("accept", "application/json")

    {:ok, conn: conn, workspace: workspace}
  end

  describe "GET /api/w/:workspace/tickets" do
    test "lists tickets", %{conn: conn, workspace: workspace} do
      insert_ticket!(%{workspace_id: workspace.id, title: "T1"})

      conn = get(conn, "/api/w/#{workspace.slug}/tickets")
      assert %{"tickets" => [%{"title" => "T1"}]} = json_response(conn, 200)
    end

    test "filters by type", %{conn: conn, workspace: workspace} do
      insert_ticket!(%{workspace_id: workspace.id, type: :bug, title: "Bug1"})
      insert_ticket!(%{workspace_id: workspace.id, type: :feature, title: "Feat1"})

      conn = get(conn, "/api/w/#{workspace.slug}/tickets?type=bug")
      %{"tickets" => tickets} = json_response(conn, 200)

      assert length(tickets) == 1
      assert hd(tickets)["type"] == "bug"
    end

    test "filters by priority", %{conn: conn, workspace: workspace} do
      insert_ticket!(%{workspace_id: workspace.id, priority: 1, title: "P1"})
      insert_ticket!(%{workspace_id: workspace.id, priority: 3, title: "P3"})

      conn = get(conn, "/api/w/#{workspace.slug}/tickets?priority=1")
      %{"tickets" => tickets} = json_response(conn, 200)

      assert length(tickets) == 1
      assert hd(tickets)["priority"] == 1
    end

    test "combines type and priority filters", %{conn: conn, workspace: workspace} do
      insert_ticket!(%{workspace_id: workspace.id, type: :bug, priority: 1, title: "B1"})
      insert_ticket!(%{workspace_id: workspace.id, type: :bug, priority: 3, title: "B3"})
      insert_ticket!(%{workspace_id: workspace.id, type: :feature, priority: 1, title: "F1"})

      conn = get(conn, "/api/w/#{workspace.slug}/tickets?type=bug&priority=1")
      %{"tickets" => tickets} = json_response(conn, 200)

      assert length(tickets) == 1
      assert hd(tickets)["title"] == "B1"
    end

    test "ignores invalid priority", %{conn: conn, workspace: workspace} do
      insert_ticket!(%{workspace_id: workspace.id, title: "T1"})

      conn = get(conn, "/api/w/#{workspace.slug}/tickets?priority=invalid")
      %{"tickets" => tickets} = json_response(conn, 200)

      assert length(tickets) == 1
    end

    test "filters by status", %{conn: conn, workspace: workspace} do
      insert_ticket!(%{workspace_id: workspace.id, status: :backlog, title: "BL"})
      insert_ticket!(%{workspace_id: workspace.id, status: :in_progress, title: "IP"})

      conn = get(conn, "/api/w/#{workspace.slug}/tickets?status=backlog")
      %{"tickets" => tickets} = json_response(conn, 200)

      assert length(tickets) == 1
      assert hd(tickets)["status"] == "backlog"
    end

    test "sorts by priority asc", %{conn: conn, workspace: workspace} do
      insert_ticket!(%{workspace_id: workspace.id, priority: 3, title: "P3"})
      insert_ticket!(%{workspace_id: workspace.id, priority: 1, title: "P1"})

      conn = get(conn, "/api/w/#{workspace.slug}/tickets?sort_by=priority&sort_order=asc")
      %{"tickets" => tickets} = json_response(conn, 200)

      priorities = Enum.map(tickets, & &1["priority"])
      assert priorities == Enum.sort(priorities)
    end
  end

  describe "GET /api/w/:workspace/tickets/:id (show)" do
    test "returns ticket by UUID", %{conn: conn, workspace: workspace} do
      ticket = insert_ticket!(%{workspace_id: workspace.id, title: "ByUUID"})

      conn = get(conn, "/api/w/#{workspace.slug}/tickets/#{ticket.id}")
      %{"ticket" => t} = json_response(conn, 200)
      assert t["title"] == "ByUUID"
    end

    test "returns ticket by number", %{conn: conn, workspace: workspace} do
      ticket = insert_ticket!(%{workspace_id: workspace.id, title: "ByNumber"})

      conn = get(conn, "/api/w/#{workspace.slug}/tickets/#{ticket.number}")
      %{"ticket" => t} = json_response(conn, 200)
      assert t["title"] == "ByNumber"
    end

    test "returns 404 for nonexistent ticket", %{conn: conn, workspace: workspace} do
      conn = get(conn, "/api/w/#{workspace.slug}/tickets/#{Ecto.UUID.generate()}")
      assert json_response(conn, 404)
    end
  end

  describe "POST /api/w/:workspace/tickets" do
    test "creates a ticket", %{conn: conn, workspace: workspace} do
      conn =
        post(conn, "/api/w/#{workspace.slug}/tickets", %{
          "ticket" => %{"title" => "New ticket", "type" => "bug"}
        })

      %{"ticket" => t} = json_response(conn, 201)
      assert t["title"] == "New ticket"
      assert t["type"] == "bug"
      assert t["status"] == "backlog"
      assert is_integer(t["number"])
    end

    test "creates a ticket with a workspace member assignee", %{conn: conn, workspace: workspace} do
      conn =
        post(conn, "/api/w/#{workspace.slug}/tickets", %{
          "ticket" => %{
            "title" => "Assigned API ticket",
            "type" => "bug",
            "assignee" => "TestUser"
          }
        })

      %{"ticket" => t} = json_response(conn, 201)
      assert t["assignee"] == "TestUser"
    end

    test "returns 422 for invalid params", %{conn: conn, workspace: workspace} do
      conn =
        post(conn, "/api/w/#{workspace.slug}/tickets", %{
          "ticket" => %{"title" => ""}
        })

      assert %{"errors" => %{"title" => ["Can't be blank"]}} = json_response(conn, 422)
    end

    test "returns 422 for assignee outside the workspace", %{conn: conn, workspace: workspace} do
      other_workspace = insert_workspace!(%{name: "API Other Workspace"})
      outsider = insert_user!(%{name: "Other Workspace Member"})
      insert_membership!(other_workspace, outsider)

      conn =
        post(conn, "/api/w/#{workspace.slug}/tickets", %{
          "ticket" => %{
            "title" => "Invalid assignee ticket",
            "type" => "bug",
            "assignee" => "Other Workspace Member"
          }
        })

      assert %{"errors" => %{"assignee" => [message]}} = json_response(conn, 422)
      assert String.contains?(String.downcase(message), "workspace member")
    end

    test "creates a ticket with blocked_by and dispatchability fields", %{
      conn: conn,
      workspace: workspace
    } do
      blocker = insert_ticket!(%{workspace_id: workspace.id, status: :backlog})

      conn =
        post(conn, "/api/w/#{workspace.slug}/tickets", %{
          "ticket" => %{
            "title" => "Dependent ticket",
            "type" => "bug",
            "blocked_by" => [blocker.id]
          }
        })

      %{"ticket" => t} = json_response(conn, 201)
      assert t["blocked_by"] == [blocker.id]
      assert t["dispatchable"] == false
      assert is_integer(t["queue_position"])
    end

    test "returns explicit blocked_by validation errors for invalid blocker refs", %{
      conn: conn,
      workspace: workspace
    } do
      conn =
        post(conn, "/api/w/#{workspace.slug}/tickets", %{
          "ticket" => %{
            "title" => "Dependent ticket",
            "type" => "bug",
            "blocked_by" => [Ecto.UUID.generate()]
          }
        })

      assert %{"errors" => %{"blocked_by" => [message]}} = json_response(conn, 422)
      assert String.contains?(String.downcase(message), "invalid blocker references")
    end

    test "returns 400 when ticket key is missing", %{conn: conn, workspace: workspace} do
      conn = post(conn, "/api/w/#{workspace.slug}/tickets", %{})
      assert json_response(conn, 400)
    end
  end

  describe "PATCH /api/w/:workspace/tickets/:id" do
    test "updates a ticket", %{conn: conn, workspace: workspace} do
      ticket = insert_ticket!(%{workspace_id: workspace.id, title: "Old"})

      conn =
        patch(conn, "/api/w/#{workspace.slug}/tickets/#{ticket.id}", %{
          "ticket" => %{"title" => "Updated"}
        })

      %{"ticket" => t} = json_response(conn, 200)
      assert t["title"] == "Updated"
    end

    test "allows clearing assignee", %{conn: conn, workspace: workspace} do
      ticket =
        insert_ticket!(%{workspace_id: workspace.id, title: "Assigned", assignee: "TestUser"})

      conn =
        patch(conn, "/api/w/#{workspace.slug}/tickets/#{ticket.id}", %{
          "ticket" => %{"assignee" => ""}
        })

      %{"ticket" => t} = json_response(conn, 200)
      assert t["assignee"] == nil
    end

    test "updates by ticket number", %{conn: conn, workspace: workspace} do
      ticket = insert_ticket!(%{workspace_id: workspace.id, title: "Old"})

      conn =
        patch(conn, "/api/w/#{workspace.slug}/tickets/#{ticket.number}", %{
          "ticket" => %{"title" => "Via Number"}
        })

      %{"ticket" => t} = json_response(conn, 200)
      assert t["title"] == "Via Number"
    end

    test "returns 404 for nonexistent ticket", %{conn: conn, workspace: workspace} do
      conn =
        patch(conn, "/api/w/#{workspace.slug}/tickets/#{Ecto.UUID.generate()}", %{
          "ticket" => %{"title" => "X"}
        })

      assert json_response(conn, 404)
    end

    test "rejects assignee from another workspace", %{conn: conn, workspace: workspace} do
      ticket = insert_ticket!(%{workspace_id: workspace.id, title: "Old"})
      other_workspace = insert_workspace!(%{name: "Update Other Workspace"})
      outsider = insert_user!(%{name: "Cross Workspace Member"})
      insert_membership!(other_workspace, outsider)

      conn =
        patch(conn, "/api/w/#{workspace.slug}/tickets/#{ticket.id}", %{
          "ticket" => %{"assignee" => "Cross Workspace Member"}
        })

      assert %{"errors" => %{"assignee" => [message]}} = json_response(conn, 422)
      assert String.contains?(String.downcase(message), "workspace member")
    end

    test "rejects dependency cycles with explicit validation errors", %{
      conn: conn,
      workspace: workspace
    } do
      a = insert_ticket!(%{workspace_id: workspace.id, title: "A"})
      b = insert_ticket!(%{workspace_id: workspace.id, title: "B"})

      _ =
        patch(conn, "/api/w/#{workspace.slug}/tickets/#{a.id}", %{
          "ticket" => %{"blocked_by" => [b.id]}
        })

      conn =
        patch(conn, "/api/w/#{workspace.slug}/tickets/#{b.id}", %{
          "ticket" => %{"blocked_by" => [a.id]}
        })

      assert %{"errors" => %{"blocked_by" => [message]}} = json_response(conn, 422)
      assert String.contains?(String.downcase(message), "dependency cycle")
    end
  end

  describe "POST /api/w/:workspace/tickets/reorder" do
    test "reorders queue positions without mutating ticket identity", %{
      conn: conn,
      workspace: workspace
    } do
      %{"ticket" => first} =
        conn
        |> post("/api/w/#{workspace.slug}/tickets", %{
          "ticket" => %{"title" => "First", "type" => "bug"}
        })
        |> json_response(201)

      %{"ticket" => second} =
        conn
        |> post("/api/w/#{workspace.slug}/tickets", %{
          "ticket" => %{"title" => "Second", "type" => "bug"}
        })
        |> json_response(201)

      %{"ticket" => third} =
        conn
        |> post("/api/w/#{workspace.slug}/tickets", %{
          "ticket" => %{"title" => "Third", "type" => "bug"}
        })
        |> json_response(201)

      conn =
        post(conn, "/api/w/#{workspace.slug}/tickets/reorder", %{
          "ticket_ids" => [third["id"], first["id"], second["id"]]
        })

      %{"queue" => queue} = json_response(conn, 200)
      assert Enum.map(queue, & &1["ticket_id"]) == [third["id"], first["id"], second["id"]]
      assert Enum.map(queue, & &1["position"]) == [0, 1, 2]

      conn = get(conn, "/api/w/#{workspace.slug}/tickets/#{first["id"]}")
      %{"ticket" => updated_first} = json_response(conn, 200)
      assert updated_first["number"] == first["number"]
    end

    test "returns validation errors when reorder payload is incomplete", %{
      conn: conn,
      workspace: workspace
    } do
      %{"ticket" => first} =
        conn
        |> post("/api/w/#{workspace.slug}/tickets", %{
          "ticket" => %{"title" => "First", "type" => "bug"}
        })
        |> json_response(201)

      _ =
        conn
        |> post("/api/w/#{workspace.slug}/tickets", %{
          "ticket" => %{"title" => "Second", "type" => "bug"}
        })
        |> json_response(201)

      conn =
        post(conn, "/api/w/#{workspace.slug}/tickets/reorder", %{
          "ticket_ids" => [first["id"]]
        })

      assert %{"errors" => %{"ticket_ids" => [message]}} = json_response(conn, 422)
      assert String.contains?(String.downcase(message), "queued ticket id exactly once")
    end
  end

  describe "GET /api/w/:workspace/tickets/:id/export/markdown" do
    test "returns markdown with content-disposition header", %{conn: conn, workspace: workspace} do
      ticket =
        insert_ticket!(%{
          workspace_id: workspace.id,
          title: "Export me",
          description: "Some desc"
        })

      conn = get(conn, "/api/w/#{workspace.slug}/tickets/#{ticket.number}/export/markdown")

      assert response_content_type(conn, :markdown) =~ "text/markdown"

      assert get_resp_header(conn, "content-disposition") == [
               ~s(attachment; filename="#{workspace.prefix}-#{ticket.number}.md")
             ]

      body = response(conn, 200)
      assert body =~ "# ##{ticket.number}: Export me"
      assert body =~ "## Description"
      assert body =~ "Some desc"
    end

    test "returns 404 for nonexistent ticket", %{conn: conn, workspace: workspace} do
      conn = get(conn, "/api/w/#{workspace.slug}/tickets/#{Ecto.UUID.generate()}/export/markdown")
      assert json_response(conn, 404)
    end
  end

  describe "DELETE /api/w/:workspace/tickets/:id" do
    test "deletes a ticket", %{conn: conn, workspace: workspace} do
      ticket = insert_ticket!(%{workspace_id: workspace.id})

      conn = delete(conn, "/api/w/#{workspace.slug}/tickets/#{ticket.id}")
      assert %{"ok" => true} = json_response(conn, 200)
    end

    test "returns 404 for nonexistent ticket", %{conn: conn, workspace: workspace} do
      conn = delete(conn, "/api/w/#{workspace.slug}/tickets/#{Ecto.UUID.generate()}")
      assert json_response(conn, 404)
    end
  end
end
