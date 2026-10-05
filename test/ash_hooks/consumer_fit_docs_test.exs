defmodule AshHooks.ConsumerFitDocsTest do
  @moduledoc """
  Doc tripwires for the first-serious-consumer integration's
  documentation asks — each assertion names the consumer scenario its
  finding came from, and each can go RED by deleting the doc line it
  guards (silently dropping an obligation from the extension site is the
  failure mode these catch).

    * H5 — the seven injected write actions arrive unpoliced on the
      consumer side; the obligation to cover them must live AT the
      extension site (the inbound half's "you write your own" precedent).
    * H7 — a generated `Event.id` turns every producer re-fire into a
      duplicate POST per sweep; the derive-from-artifact-id contract must
      live in the Event and Dispatcher docs.
    * M1 — a map-headers adapter (Req 0.7) silently loses `Retry-After`;
      the list-shaped header contract and the resolve-and-pin obligation
      must live in the adapter behaviour's doc.
    * M2 — `retry_after_cap_seconds` defaults to 86,400 (receiver-held
      state for up to 24h per attempt); the implication must be stated at
      the option.
    * M6 — the 410 auto-disable is an unattributed system bulk write with
      no tenant visibility story; the silent-dark posture and the
      telemetry seam must be stated at the classification table.
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
            :requeue,
            :prune,
            :mark_sending,
            :mark_succeeded,
            :mark_send_failed
          ] do
        assert doc =~ ":#{action}", "the policy obligation must name #{action}"
      end

      assert doc =~ "POLICY OBLIGATION"
    end

    test "Endpoint names the injected :disable" do
      doc = moduledoc(AshHooks.Endpoint)
      assert doc =~ ":disable"
      assert doc =~ "POLICY OBLIGATION"
    end
  end

  describe "H7: deterministic Event.id guidance" do
    test "Event states the derive-from-artifact contract" do
      doc = moduledoc(AshHooks.Event)
      assert doc =~ "DETERMINISTIC"
      assert doc =~ "duplicate POST"
    end

    test "Dispatcher's example derives the id from the artifact" do
      doc = moduledoc(AshHooks.Dispatcher)
      assert doc =~ "msg_order-"
      assert doc =~ "DETERMINISTIC"
    end
  end

  describe "M1: the adapter-author contract" do
    test "Http names the list-shaped header contract" do
      doc = moduledoc(AshHooks.Http)
      assert doc =~ "LIST of `{name, value}`"
      assert doc =~ "Retry-After"
    end

    test "Http names the resolve-and-pin obligation" do
      doc = moduledoc(AshHooks.Http)
      assert doc =~ "Resolve-and-pin"
      assert doc =~ "Target.resolve"
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
      assert doc =~ "SILENTLY"
      assert doc =~ "[:ash_hooks, :delivery, :disable]"
    end
  end
end
