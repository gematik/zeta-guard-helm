# Installing an event listener provider is not enough: Keycloak only invokes the
# ones the realm lists, and its default is jboss-logging alone. Event storage
# stays off — listeners are called regardless of events_enabled/admin_events_enabled,
# which only gate persistence (EventBuilder line 73, AdminEventBuilder.updateStore).
#
# This list is exhaustive and all-or-nothing: Keycloak rejects the whole update if
# it names a provider that is not installed, leaving the previous list in place, so
# a typo or a removed plugin disables *every* listener here without failing loudly.
# Add an id only together with the provider, and remove both in the same change.
resource "keycloak_realm_events" "zeta_realm_events" {
  realm_id = keycloak_realm.zeta_realm.id

  events_enabled       = false
  admin_events_enabled = false

  events_listeners = [
    "jboss-logging",
    # Session revocation: turns logouts, grant revocations and admin session
    # deletes into block-list entries the PEPs consume over SSE.
    "zeta-guard-revocation-events",
  ]
}
