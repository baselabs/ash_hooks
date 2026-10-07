defmodule AshHooks.ConsumerFitDocsTest do
  @moduledoc """
  Guards documented caller responsibilities: generated action policies,
  stable event identity, adapter response shape and connection pinning,
  retry timing, and endpoint-disable visibility.
  """

  use ExUnit.Case, async: true

  defp moduledoc(module) do
    {:docs_v1, _, _, _, %{"en" => doc}, _, _} = Code.fetch_docs(module)
    doc
  end

  describe "H5: the policy obligation at the extension site" do
    test "OutboundDelivery names every injected write action" do
      doc = moduledoc(AshHooks.OutboundDelivery)

      for action <- [
            :dispatch,
            :mark_enqueue_failed,
            :bind_dispatch_source,
            :bind_dispatch_route,
            :claim_enqueue,
            :release_enqueue,
            :requeue,
            :prune,
            :mark_sending,
            :mark_succeeded,
            :mark_send_failed,
            :mark_disable_pending,
            :finalize_disable
          ] do
        assert doc =~ ":#{action}", "the policy obligation must name #{action}"
      end

      assert String.downcase(doc) =~ "policy obligation"
    end

    test "Endpoint names the injected :disable" do
      doc = moduledoc(AshHooks.Endpoint)
      assert doc =~ ":disable"
      assert String.downcase(doc) =~ "policy obligation"
    end
  end

  describe "H7: deterministic Event.id guidance" do
    test "Event states the derive-from-artifact contract" do
      doc = moduledoc(AshHooks.Event)
      assert String.downcase(doc) =~ "deterministic"
      assert doc =~ "duplicate POST"
    end

    test "Dispatcher's example derives the id from the artifact" do
      doc = moduledoc(AshHooks.Dispatcher)
      assert doc =~ "msg_order-"
      assert String.downcase(doc) =~ "deterministic"
    end
  end

  describe "M1: the adapter-author contract" do
    test "Http names the list-shaped header contract" do
      doc = moduledoc(AshHooks.Http)
      assert String.downcase(doc) =~ "list of `{name, value}`"
      assert doc =~ "Retry-After"
    end

    test "Http names the resolve-and-pin obligation" do
      doc = moduledoc(AshHooks.Http)
      assert doc =~ "Resolve-and-pin"
      assert doc =~ "AshHooks.Ssrf.resolve_public/1"
    end
  end

  describe "M2: the Retry-After cap semantics" do
    test "Worker states the receiver-held-state implication of the 86,400 default" do
      doc = moduledoc(AshHooks.Worker)
      assert doc =~ "receiver-held-state"
      assert doc =~ "24 hours"
    end
  end

  describe "M6: the 410 auto-disable implications" do
    test "Delivery states the unattributed/silent-dark posture and the telemetry seam" do
      doc = moduledoc(AshHooks.Delivery)
      assert doc =~ "unattributed"
      assert String.downcase(doc) =~ "silently"
      assert doc =~ "[:ash_hooks, :delivery, :disable]"
    end
  end
end
