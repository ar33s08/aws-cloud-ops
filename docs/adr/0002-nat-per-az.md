# ADR 0002: One NAT gateway per Availability Zone in production, one in development

- Status: accepted
- Date: 2025-11-10

## Context

The network module (`infra/modules/network`) builds a private-only estate:
no subnet of the design is public, no workload subnet carries a default route
to the internet gateway, and every private route table sends its default
route to a NAT gateway. That single egress path is used for the things that
keep an estate alive: the Systems Manager agent checking in, the package
mirrors being polled, the monitoring agent shipping its metrics, a service
pulling a container image. When the NAT gateway is unhealthy or saturated,
those flows do not slow down -- instances drop off, and the estate loses its
agents exactly when it most needs them, during the patch window.

The module reference (the `README.md` beside the module) documents the
single-NAT starting position, in which all three private subnets share one
gateway. The question this record answers is whether that starting position
is also the end position, for production and for development.

## Decision

In production, one NAT gateway is created per Availability Zone the estate
occupies, each in that zone's own connectivity subnet, and each private
subnet's route table sends its default route to the gateway of *its own*
zone. There is no cross-zone NAT route in the production route tables.

In development, one NAT gateway serves the whole environment.

The cross-zone path remains available as a deliberate failure mode: if the
gateway of a zone is destroyed, that zone loses internet, and workloads in
it do not borrow the neighbour's gateway. That is the point -- an outage
must be visible, contained, and attributable to one fault domain, not
smuggled into another zone as latency nobody has measured.

## Consequences

The good side:

- A single gateway fault domain per zone bounds the blast radius: a bad
  availability zone, or one gateway, removes egress for one zone instead of
  for the estate.
- Egress traffic stays within the zone in which the workload runs, which
  removes the cross-zone hop from the data path of the agents and their
  probes, and keeps the network metrics attributable per zone.
- The failure is observable on the per-zone gateway metrics; on-call can
  graph the traffic of one zone against the others and see the outage
  without parsing application logs.

The bad side, stated honestly:

- Cost. Every NAT gateway is billed, continuously, for its configuration
  and for the data it processes, and running one per zone multiplies that
  line by the width of the zone set of the estate. We accept this as a
  trade-off rather than a number: the figure changes with the pricing of the
  region and with the traffic of the estate, so this record deliberately
  quotes none, and the cost of the decision must be evaluated whenever the
  account billing report is reviewed, not assumed here. What is fixed is
  the shape of the argument: the premium buys fault tolerance of the
  private estate, and the estate considers the premium worth paying in view
  of the maintenance windows through which the patch programme flows.
- More gateways means more route tables to audit and more resources for the
  configuration to carry; a missing gateway, like a missing dependency in
  the package manifest, must be caught by the drift detector before the
  next plan reveals it. The drift comparison is given in the weekly report
  (see `OPERATIONS.md`).

Development keeps the single gateway because its traffic is light, its
maintenance window is the whole week, and the purpose of the environment is
to make failures cheap to see, not cheap to survive.
