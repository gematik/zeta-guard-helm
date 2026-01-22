<img align="right" width="250" height="47" src="docs/img/Gematik_Logo_Flag.png"/> <br/>

# Release Notes ZETA Guard Helm Charts

## Release 0.2.8

### changed:
- authserver and testdriver/exauthsim now have separate keystores/truststores.
  This chart now includes an RU based truststore for the authserver. For the
  testdriver/exauthsim you still need to bring your own cert&key. 
- The values for the SMCB keystore have changed slightly. Now they are
  `smcb_keystore.keystore` and `smcb_keystore.password` with the same semantics.
  No changes are needed when using the makefile for the test setup.

## Release 0.2.7

### added:
- ability to configure external DBs. See helm values authserverDb.* in zeta-guard subchart
- improvements for better compliance with some kubernetes security policies

### changed:
- Makefile: streamlined stage/namespace/values selection; safer templating; clearer help
- Enforce admin-password of Authserver on initial deployment

## Release 0.2.6

### added:
- config for ASL test mode
- improved Betriebsdatenlieferung

### changed:
- updated versions of several subcomponents

## Release 0.2.5

### changed:
- fix missing opa service account
- fix popp token config

## Release 0.2.4

### added:
- missing file(s) for local deployments

### changed:
- minor doc improvements
- updated individual components to their newes versions
- functional userdata and clientdata headers (beware clientdata schema is still subject to change)

## Release 0.2.0

### added:
- bundling functionality of milestone 2 incl client registration, smcb token exchange
- public release of test setup

## Release 0.1.3

### added:
- Helm chart for the prototype of ZETA Guard added
