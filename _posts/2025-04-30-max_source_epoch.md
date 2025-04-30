---
title: "MAX_SOURCE_EPOCH"
date: 2025-04-29T17:34:30-04:00
layout: post
---

## Abstract

This document discusses how to prevent a premature forward step of the
source epoch number in the Casper FFG vote for validators. If the
validator submits an attestation prematurely with a source epoch
number that is too high, the validator's stake is at risk if it ends
up on a super-majority fork, that is later declared invalid by
social-consensus.

This document explores strategies for validators on how to detect
forks from the beacon API of a set of backend nodes. None of these
strategies are part of Ethereum's consensus algorithm and are
individual choices of the validator. While safety, i.e. detecting
forks, is the primary goal, retaining good latency for producing
attestation data and retaining reasonable maintenance windows for
backend node software upgrades are important secondary goals.

## The Holesky Pectra incident

During the Pectra upgrade of the Holesky testnet, a consensus critical
bug affected Geth, Nethermind and Besu (short Gethersu). Reth and
Erigon didn't have the same bug (short Rerigon). The chain forked with
Gethersu on one side and Rerigon on the other. Gethersu had a
super-majority of validators, which led to Gethersu justifying a
checkpoint behind the fork point.

Once a checkpoint justifies, validators must use this checkpoint in
their source vote in their Casper FFG vote. While the exact checkpoint
hash in the source voting data is of no consequence, the increase in
the epoch number in the source vote has significant consequences for
validators caught on the wrong side of the fork. Before we explain
why, let us review Casper FFG.

### What's Casper FFG?

Casper FFG is the finality consensus algorithm on top of Ethereum
introduced by [Vitalik and
Virgil](https://arxiv.org/abs/1710.09437). The Casper vote is a vote
for path on a tree, voting from a justified source checkpoint to an
unjustified target checkpoint. A checkpoint consists of a hash and an
epoch. So a Casper FFG vote has four elements: source.hash,
source.epoch, target.hash, target.epoch. We use the following
notations:

* We use X→Y as a vote from source epoch X to target epoch Y.

* We use X@source_hash → Y@target_hash if the exact hashes matter
for the discussion.

Casper FFG requires honest participants and makes voting incorrectly a
slashable offence. One of those offenses is casting votes, where the
source and target epoch range covered by one vote falls fully inside
the source and target epoch range covered of another vote. For
instance, the vote 2→3 is fully inside the vote of 1→4, so is
3→9 for 1→17. that is not the case for the votes 1→2 & 2→3,
or the votes 1→2&1→3. This is called surround vote
slashing. Formally if we have two attestations a1 and a2, then the
surround vote rule is violated if:

```
a1.source.epoch < a2.source.epoch && a2.target.epoch < a1.target.epoch
```

Note the use of strict greater-than operators. If we have two votes
originating from the same source epoch, the vote **is not** subject to
surround vote slashing.

### A normal epoch rollover

The shortest possible Casper FFG vote is X→X+1 and the earliest
possible point in which it can be cast is slot 0 of epoch X+1 for
inclusion in the block of slot 1. For the rest of the epoch X+1, the
vote stays the same.

When the next slot 0 of the next epoch (X+2) becomes available, the
target vote for X+1 has gathered enough attestations to cross the 66%
threshold, so at the end of epoch X+1, X+1 immediately justifies and
becomes the source vote for votes in the next epoch X+2. So during
normal operations during epoch X, validators cast their Casper FFG
votes as \(\text{Checkpoint}_{X-1} → \text{Checkpoint}_{X} \).

### Slot 29 of Epoch 115968 on Holesky

Shortly after the Pectra activation a new transaction triggered a new
consensus path. The consensus-breaking transaction <!-- FIXME: link to the exact TX --> was included in slot 29 of [epoch
115968](https://light-holesky.beaconcha.in/epoch/115968) and caused an execution
on Gethersu different from the one of Rerigon and the chain
forked. A super-majority progressed with its side of the fork,
while a minority progressed into a different direction. This had the
following effect on the Casper FFG votes:

* On both side, the epoch 115968 checkpoint had gathered enough target
  votes to justify as new source.

* The Gethersu side progressed normal. Slot 0 of epoch 115969 came
  around and became the new target vote for this side. Eventually
  epoch 115969 gathered enough target votes to justify. As epoch
  115970 passed with validators casting votes with source epoch =
  115969, the attesting validators were trapped themselves on the
  majority side.

* On the minority side the block production effectively collapsed
  after epoch 115968. Eventually the Rerigon side managed to produce a
  few blocks, some of which became new target votes in the Casper FFG
  votes. In contrast to the Gethersu side, the Rerigon side never had
  another source epoch justify after 115968. The epoch number was
  stuck at 115968 for the source epoch. Votes with a higher network
  were rejected by this side, because including attestations with a
  higher source epoch would violate block wellformedness rules.

<!--
* On the Rerigon minority side, the justification for X did not happen, so
  X-1 was still the last justified checkpoint.  Minority attesters
  which casted votes for X-1 → X, casted X-1 → X+1 votes after
  the fork happened. Note that only on minority chains there can be an
  epoch gap greater than 1 in the Casper FFG vote. As the minority
  chain progressed the votes had the shapes X-1 → X+2, X-1 → X+3
  and so forth.
* On the Gethersu majority side, X justified. So votes took the form
  X → X+1. After that X+1 justified, so votes took the form X+1 →
  X+2, then X+2 justified with voters switching to X+2 → X+3 and
  so forth.
-->

### The cleanup attempt

Once the community discovered the problem, the Gethersu side shut down
their node and operators tried to switch their validators from the
Gethersu side to Rerigon. Most validators however have slashing
protection databases that prevented the switch. Here is why.

In order for former-Gethersu attesters to participate on the Rerigon
side, they must cast the source vote starting from the last justified
checkpoint on that side. For Rerigon that was 115968. Also the target
must be close to the current slot. When Gethersu operators were ready
to switch, the target vote progressed far away from 115968 and might
have taken a form like this 115968 → 116XXX. But here comes the
problem: Gethersu attesters have casted the vote 115969 → 115970
before the switch and this vote is inside the range of 115968→116XXX,
which they now must cast to participate on the Rerigon side. But the
latter vote triggers the surround voting condition and leads to a
slashing.

### A detour of the inactivity leak and correlation penalties

Okay, what's so bad about slashing? You heard that in Electra, they
reduced the penality even further. It's like 0.032 ETH now, right? So
let us move forward and switch sides.

Not so fast. There is an additional mechanism in the consensus spec
that amplifies the penalty by the sum of all the penalties that
happened in the last X epochs.<!-- FIXME add link to mainnet.py:LX
here to the relevant function --> For an event like Holesky with more
than 66% of validator being wrong, the penalties applify so much that
you lose all your stake.

Well, then you just wait it out and don't switch, right? Sadly this
means that you lose at least half of your stake due to inactivity, and
when you are ejected from consensus (<16ETH), you still need to wait till
you passed the exit queue, which kills the rest of your stake, because
the inactivity leak doesn't stop for validators queued for the
exit. At the end you are left with 0.

So getting slashed and waiting both lead to the same result. A full
lose of your stake. As there is no good answer, once you got caught
with a surround slashable vote, the best strategy is to avoid a
surround slashable vote *at all costs* (because it will literally
costs you everything).

<!-- ### Who moves first? 

Even if operators found that there was a problem (let us say within 10
minutes - 20 minutes), their validators will already have broadcasted
the problematic first vote X → X+1.

Once the minority side justifies again, the source epoch vote would
move forward, let us say to X+300, which changes the votes to look
like X+300 → X+301. This vote is not subject to surround slashing
as X → X+1 does not surround X+300 → X+301. So if for some
reason, the minority chain justifies, attesters can switch without the
risk of surround vote slashing. However, affected attesters can't just
wait, because the inactivity leak will eat away at least half their
stake. So somebody has to move, get slashed, and enable the
minority-chain to justify. There is no other way out. The question is
who moves first?

The answer to the above is "let us not play that game at all". The rest
of the document focused on avoiding the situation altogether. But
before we move to the next section, please note that moving the source
epoch in the Casper FFG vote forward from X to X+1 is the problem for
the super-majority attesters. If they would have avoided that step,
they would have been fine. 
-->

## Defining a safe high watermark

So what's exactly the point at which things went wrong for a Gethersu
validator in the Holesky Pectra incident? It was at the first vote
that validators casted with source epoch greater than the last
justified epoch on the Rerigon side, namely 115969. If validators
would have stick to 115968 as source vote, things would have been fine
for them. 115968 would have been the last safe high watermark.

If we can somehow "guess" that there is a minority fork "somewhere out
there" for which the source epoch has not moved, we could use that
information to suppress our validator from casting source vote that starts
beyond a safe high watermark. We call this high watermark number
MAX_SOURCE_EPOCH.

Let’s suppose that we are omniscient for a moment. If
we know all consensus node states at a moment in time, how would we
pick MAX_SOURCE_EPOCH? A single weird node somewhere on the network,
with an old network version, with faulty memory and a spotty uplink
would probably cast a Casper FFG vote that is not particularly
relevant. Whatever fork an isolated or broken node is on, it is
unlikely to survive long-term.

We need to focus on forks that have some type of chance to survive
longer. Historically, we have seen forks survive along the client
implementation boundaries. So if we'd be omniscient we would focus on
differences between e.g. all Geth nodes and all Reth nodes.

Assume that from our omniscience, we know \( \text{SOURCE\_EPOCH}(c, e, s)
\), the epoch number that the majority of nodes with consensus client
\( c \) and execution client \( e \) source-voted for in slot s. Then
a safe definition for \( \text{MAX\_SOURCE\_EPOCH(s)} \) would be:

\[ min(∀c ∈ C , ∀e ∈ E: \text{SOURCE\_EPOCH}(c, e, s)). \]

where

\[ C = \{\text{Prysm}, \text{Nimbus}, \text{Teku}, \text{Lodestar}, \text{Grandine}, \text{Lighthouse} \} \\
   E = \{\text{Geth}, \text{Besu}, \text{Nethermind}, \text{Erigon}, \text{Reth}\}
\]

In other words, if a single client pair disagrees and has a lower
source epoch, we should not source-vote above that epoch.

### Practical information sources

Omniscience is somewhat hard. What are more realistic ways to
approximate our definition of MAX_SOURCE_EPOCH from above? We
potentially have three sources of information:

* If forks fall along the boundaries of client implementations, use
  multiple client implementations. This obviously provides more
  information about actual client implementation behaviour than just
  running a single stack. We discuss strategies based on multiple
  backends under the "Local strategies" section below.

* We could use block data. We discuss strategies on block data in the
  "Global strategies" section.

* Use in-flight P2P attestation data from the network (not explored in
  this document).


<!---
The Beacon Chain API provides the [attestation_data
endpoint](https://ethereum.github.io/beacon-APIs/#/Validator/produceAttestationData),
which validators query for voting data to BLS sign and submit. The
voting data includes the source vote for Casper FFG, which is a tuple
of epoch number and checkpoint.

This document is about preventing a source voting for an epoch number
so high that this height is not universally accepted as
justified. Normally a target vote transitions to a source vote at the
end of the epoch because two criteria are met:

* The next target checkpoint becomes available only at slot 0 of the
  next epoch. So the current target vote can only become the new
  source vote at slot 0 of the next epoch.

* Additionally, the target vote must have received the approval of
  more than 66% of the validators. Given that mainnet efficiency is
  around 98%, somewhere around slot 24 of the current epoch, our
  beacon node has already seen enough attestations in the blocks
  before to confirm the current target vote (slot 0 of the current
  epoch) once the epoch ends.
-->

## Local strategies

One approximation to omniscience is to install many CL/EL combinations
locally and assume all nodes on the network exhibit the same behavior
as your own nodes. With 6 CL and 5 EL client, that is 30
installations. That sounds like a lot. If we are willing to ignore
pairing bugs (bugs that just occur on a specific CL/EL), we get away
with much few CL/EL installations. Head over to
[supermajority.info](https://supermajority.info/simulator) and check
the risk simulator. Clients with a share bigger than 33% can be
ignored as them forking off leads to an immediate failure to justify.

<!-- INSERT EL screenshot here. -->

Let’s now see how to aggregate the attestation data from all our
backends nodes.

<!-- ## During normal operations

Source Epoch is the previous epoch from slot 0-31. The only time
critical vote is 0. If we decided to vote in slot 0 for a new epoch,
we don't make a new decision for around 30 slots. This gives us a
maintenance window of an epoch or around 6.4 minutes. This is usually
enough to restart a node with a fresh version and resync it.
-->

<!-- ## Implementation

We think that these proposal should be implemented in a reverse proxy
that speaks the Beacon API towards validators and that aggregates
respondes from the backends.
-->

<!--
As switching from the minority chain back to the majority chain is not
subject to surround vote slashing (because the majority side has a
higher source epoch), we can maybe get away with not installing the
larger clients like Geth/Nethermind/Prysm/Lighthouse. The reason is
that the network is unlikely to finalize with one of those clients
disagreeing. Too many attestations votes would fall of the network to
cross the 66% threshold. The developer community could then gracefully
recover without exposing anyone to surround vote slashing. So it is
most important to install a good set of minority clients.
-->

### Strategy 0: Force equality of all attestation data

Validator implementations like Vouch and Vero can aggregate
attestation data from multiple backends. If you have a diverse CL/EL
node set, you want attestation to stop the moment a single one
disagrees with the rest. If for instance you have 3 backend nodes, all
must respond with the same attestation data for Vouch/Vero to sign the
attestation. In Vouch this mode is called majority voting with a
threshold, where the threshold is the total number of backend
nodes. This makes the attestation process rather brittle. If a single
node has latency issues or is down for maintenance, you miss
attestation. So this strategy is hard to implement.

One way to overcome the problem of the maintenance window is to setup
a backup node for each CL/EL. E.g. 2x Prysm/Reth, 2x Nimbus/Besu, and
2x Lodestar/Erigon. Then you could run a strategy that at least one of
each kind must be present, and that among those present all
attestation data must be match. This also overcomes the problem of
uncorrelated latency issues within a single kind of nodes. However, if
a block causes latency spikes on all nodes of a single kind, because
the block is just hard to process for this CL/EL combination, then we
might again miss the attestation. So even with backup nodes, this
strategy has its drawbacks.

### Strategy 1: Looking at the Casper FFG source vote

> 1. Set MAX_SOURCE_EPOCH to zero.
  2. Query all backend in parallel. Use the first
  response as soon as it comes in, when the source epoch is smaller or equal to
  MAX_SOURCE_EPOCH. If it is not, wait for the next request and
  recheck.
  3. If by the last backend response we haven't sent a reply,
  the source epoch of all responses were higher than
  MAX_SOURCE_EPOCH. Bump MAX_SOURCE_EPOCH to min(source_epoch of
  responses).
  4. Now at least one response must pass the MAX_SOURCE_EPOCH
  check. Use that one for attesting.

This strategy is a very straight forward implementation of the
definition. It is safe to assume that our node set is diverse
enough. Here is an implementation:

```
import asyncio

async def query_backend(backend):
    # Async function to query a single backend
    ...
def use_response(response):
    ...

MAX_SOURCE_EPOCH = 0
BACKENDS = [...]

def strategy(responses):
    return min([r.source.epoch for r in responses])
    
async def get_attestation_data():
    global MAX_SOURCE_EPOCH
    responses = []
    used_response = False
    def maybe_use_response():
      for r in responses:
        if not used_response and r.source.epoch <= MAX_SOURCE_EPOCH:
          use_response(r)
          used_response = True

    pending = {asyncio.create_task(query_backend(b)) for b in BACKENDS}
    while pending:
        done, pending = await asyncio.wait(
          pending, return_when=asyncio.FIRST_COMPLETED)
        responses += [task.result() in task for done]
        maybe_use_response()
    MAX_SOURCE_EPOCH = strategy(responses) or MAX_SOURCE_EPOCH
    maybe_use_response()
    assert used_response
```

This strategy has the drawback that for the first request for slot 0 of an
epoch, all backends need to respond before we can use attestation
data.

<!--
Also assuming that each node is only
partially available \( r \) percent of the time, your overall
availability is \( r^n \) where \( n \) is the number of nodes. With
the 25 pairs strategy above, and an availability of 99.9%, your
overall availability falls to 97.5\%. Maybe you could reduce the
effective hit on your availability by coordinating all planned
downtime to occur in a single window. A better strategy would however
be to provide backup nodes to each client pair, taking the total
number of pairs to 50. If you stick with only 3 node pairs, you'd
still need 6 when factoring in backup nodes.

Throwing hardware at the problem might help with availability but
doesn't help with slowness in individual client implementations. Your
latency is the combination of the worst case consensus client and the
worst case execution client. 
Note that while the above sounds really horrible and bad, the problem
is actually just ~3% as bad. In partice the source vote is the same
throughout the epoch. Only at the epoch rollover, the source epoch
vote changes. So only at slot 0 we need to wait for all backends to
respond, taking the latency and availability hit to 3% of the problem.
-->

Let’s examine how we do with this strategy:
* Latency on slot 0 is bound by the worst case latency.
* Maintenance window of ~30 slots or 6 minutes.

### Strategy 2: Looking at the Casper FFG target vote

A Casper FFG vote not only contains a source vote but also a target
vote. By voting for a new checkpoint as target, a node signals that
this is a good checkpoint. If during an epoch more than 66% of
validators vote for that checkpoint, the checkpoint becomes the new
source.

<video width="800" controls>
  <source src="/assets/mp4/attestation_watcher.mp4" type="video/mp4">
  Your browser does not support the video tag.
</video>

Above you see a video of attestation_watcher.py. It connects to a set
of backend nodes and queries attestation data every 250ms. In the
example video above, node1 is Prysm+Reth, node2 is Lodestar+Erigon and
node3 is Nimbus+Besu. You can see how the source vote and the target
votes develop. Note how in slot 11577248 -- the first in the epoch --
you see the source vote and the target vote move forward. (The video
shows node2 Lodestar voting for 11577248→11577248. I don't think that
this is a spec compliant vote and it would not be included in any
block.)

At slot 0 of a new epoch, we not only learn about the new source vote
of all our nodes, we also learn about the new target vote of all our
nodes. We could reason the following: If we have all CL/EL
combinations installed, and all agree on a target vote, wouldn't that
automatically imply that:

1. There is no fork before the target checkpoint,
2. All nodes will continue to vote for the target checkpoint for the
   rest of the epoch, and
3. Because every node will vote for the target checkpoint the
   checkpoint *must* justify?

We could codify the strategy reusing the code above but replacing:

```
def strategy(responses)
    return min([r.target.epoch for r in responses])
```

This strategy would have indeed worked for the Holesky Pectra
incident. The fork occured at slot 29 of [epoch
115968](https://light-holesky.beaconcha.in/epoch/115968). In the slots
0-28 before, all nodes agreed on the target vote, and even after slot
30 both sides of the fork agreed on the target vote. The vote
confirmed and the source epoch became the checkpoint in which the fork
happened. So a MAX_SOURCE_EPOCH of the checkpoint right before the
Holesky Pectra fork would have been safe.

This strategy however has a problem when the fork happened earlier in
an epoch, e.g slot 0-5. In the Holesky Pectra incident, we saw block
production falling apart on the minority side right after the forking
slot, with many many slots going missing afterwards. 

Missing block production produces a problem for attestations. There is
no block space to include them. So even though all nodes on both sides
of a fork might vote for a target, if the target votes haven't crossed
the 66% threshold before block production breaks, the target vote is
still in limbo, and therefore threatens our definition
MAX_SOURCE_EPOCH.

When the minority side resumes block production, it is possible that
proposers would eventually include the attestations in limbo. The
consensus spec provides incentives to include attestations that
increase validator participation, so we could make the argument that
this should be sufficient for the pre-fork target vote to eventually
justify. However, until we see that working in practice -- for
instance in an intenationally non-finalizing testnet -- we can't
recommend this strategy.

### Strategy 3: Looking at the LMD Ghost vote

What if we use the target vote only after 2/3 of an epoch has passed
and we haven't seen a fork? That gives us a good chance that the
attestations included so far are enough to justify the target
vote. But how do we detect that?

We look at the beacon_block_roots of all our backends. If by slot
22 the beacon_block_root is the same for all of them, we conclude
that if a fork were to happen at the last third of the epoch, our
target would still justify and a source vote for the target's epoch
would be safe. We bump MAX_SOURCE_EPOCH to the target epoch sometime
after slot 22, when all nodes agree. We can do that right at slot 22
or can do it in slot 31.

```
def strategy(responses, slot):
    # All LMD-Ghost votes agree
    if len(set(r.beacon_block_root for r in responses)) != 1:
      return None
    if (slot % 32) < 22:
      return None
    return min([r.target_epoch for r in responses])
```

<!--
### Strategy 4: Recalculating attestation rates.

Strategy 3 makes the assumption that by slot 22 enough attestation
data is there to justify the target vote. that is usually the case on
mainnet. However, that is not guaranteed. So it might be the case that
none of our backends sees a fork during an epoch, the epoch

If our local backends don't signal a fork before that slot, a
fork after that slot can't prevent justifying the target vote.

However, there is a problem: What if all my backend nodes 

that is not necessarily the
case. We could inspect the blocks in slots 0-21 and recalculate how
many validators voted for a target vote. 
-->
### Strategy 4: Prejustifying target votes via an API change

What all strategies above tried to do is to guess whether a consensus
client would accept a target vote as a source vote when the epoch
rolls over. While strategy 3 -- looking at diverging LMD ghost votes
-- is a good indication for a fork, the absence of a fork doesn't mean
that the target vote justifies. What if the attestation data is just
missing in the blocks? While producers are incentivized to include
good attestations, they don't have to. A block without attestations
isn't invalid. So it might be the case that the target vote doesn't
turn into a source vote.

<!-- If in addition to that one of our nodes has an
accounting bug, and does indeed bump the source vote to the next
epoch, and we have a fork right after, we would have casted the fatal
surround slashable vote. -->

So how do we fix this? Should we come up with a strategy that parses
attestation data from the validator side, recount participation and
make a more educated guess of what the beacon node does at the end of the
epoch? I would say: No. Instead of guessing what the beacon node will
do at the end of the epoch, why don't we just ask the beacon node
itself?

The problem is that there is no standardized API in the Beacon API
surface that could give us an indication what the beacon node thinks
about its target vote. Would the beacon node accept the target vote in
the absence of further votes? If the answer is yes, I would call the
target vote "prejustified". That means: A checkpoint has gathered enough
votes to pass the 66% threshold. What prevents the node from using
this prejustified checkpoint as source vote immediately is simply that there isn't
a new checkpoint yet. Casper FFG doesn't allow votes of the form
X→X so we have to wait for the end of the epoch to get a new
checkpoint (FIXME: I am not sure that's really true. I caught Lodestar casting X→X as a vote).

While we are at it, we might as well expose the participation_rate in
the attestation data itself.

<!--
It would be very useful to understand if a beacon node would justify
the target epoch on epoch rollover. In particular, if the beacon node
would accept its target vote without any further votes from other
validator. This is the case, when the node has seen attestations from
more than 66% of the validators (and those attestations are also valid
according to the rules of the beacon node). A simple flag on the
target vote attestation data should be sufficient. But while we are at it, we might as well add the voting percentage to the reply as well.
-->

```
$ curl -s -X GET "http://node2:4020/eth/v1/validator/attestation_data?slot=11562205&committee_index=1" -H accept: application/json | jq
{
  "data": {
    "slot": "11562205",
    "index": "1",
    "beacon_block_root": "0x2f106313300b66ad00fdfb70ad75f463015c23a64167627af089a25768e19940",
    "source": {
      "epoch": "361318",
      "root": "0xc738bf887e0fe95c0467ee408fa70f8f047de6cf8e894013e7781b86fe5f90b9"
    },
    "target": {
      "epoch": "361318",
      "root": "0xc738bf887e0fe95c0467ee408fa70f8f047de6cf8e894013e7781b86fe5f90b9"
      "prejustified": true // NEW
      "participation_rate": 0.8 // NEW
    }
  }
}
```

Let’s formulate a strategy based on the prejustified flag.

> When all my local nodes have agreed on their target vote and all
  nodes prejustify the target vote, increase MAX_SOURCE_EPOCH to the
  target epoch.

```
def strategy(responses, slot):
    # All LMD-Ghost votes agree
    if not all([r.target.prejustified for r in responses]):
      return None
    if (slot % 32) < 22:
      return None
    return min([r.target_epoch for r in responses])
```

### Summary of local strategies

Strategy 1 is very straight forward to implement. We recommend starting with this strategy. If the "wait for all responses" in slot 0 of a new epoch is unacceptable latency-wise, we would recommend strategy 3. As strategy 3 isn't perfect and requires a bit of guesswork by the validator implementation, we suggest changing the Beacon API to include the participation_rate and/or a prejustified flag.

| Strategy | Latency Impact          | Maintenance window     | Risks |
| 0        | Slowest node            | 0 without backup nodes | None |
| 1        | Slowest node in  slot 0 | ~30 slots              | None |
| 2        | None                    | ~62 slots              | Relies on proposer incentives |
| 3        | None                    | ~40 slots              | End of epoch processing bug   |
| 4        | None                    | ~40 slots              | None, but unimplemented API   |


## Global strategies

In this section we explore strategies that don't depend on a local
diversified node set. The strategies might be helpful to home stakers.

### Strategy 0: Ethereum's built-in loss of finality

Ethereum has a built-in strategy to stop checkpoints from
justifying. When 33% of attestations fall of the network, the
checkpoint fails to justify. Therefore we do **not** need to install
any client with a market share higher than 33%. Should the client be
faulty, the network stops to finalize. 

![image](/assets/el.png)

Looking at the market share of Prysm (31%) it barely doesn't qualify
for this automatic protection above. However, we can tune our
validators to stop attestations if we see 32% of client weight fall of
the network. There are three places in Ethereum blocks where a drop in
participation would materialize:

* block production, and
* block confirmation (aka attestation).
* sync committee participation

### Strategy 1: Track block production

Less than 1/320 blocks are missing on mainnet by chance. That an epoch
misses more than 3 blocks by chance is extremely unlikely, \( P(X \geq
3) \approx 0.000182 \). We could stop attestations if we see an epoch
missing more than 3 blocks.

```
def strategy(responses, beacon_api)
    if missing_blocks_in_epoch(beacon_api) > 3:
      return None
    return min([r.target.epoch for r in responses])
```

### Strategy 2: Track attestation

Immediately after a fork, the Casper FFG votes for forking clients are
not different from the rest, as the target vote is pointing to the
first slot in the epoch. Only the target vote of the following epoch
would differ. However, the head votes would show an immediate
difference. Post-fork aggregation attestations should show a clear
divide and should give a relatively good indication of what percentage
of clients are following the fork. Attestations from forked validators
should show up as attestations with head votes pointing to missing
blocks.

### Strategy 3: Track sync committee participation

This strategy provides a very similar signal to looking at attestation
data.If a set of sync committee members all drop off at a specific
head vote, it provides a very strong signal that those clients forked
off. We still need to investigate the exact statistics sync committee
member performance and what would be good bounds to keep
false-positives to a minimum, yet provide a good signal to stop
attestations.

### Meta-Strategy: Correlate all the above with last graffiti.

All the strategies above can point to a validator missing it duty. If
a set of validators miss their duties, that's a stronger signal, yet
might happen purely by chance. If somehow could know the CL/EL client
software of the set of absent validators, the signal would be even
stronger.

Recently client implementations started publishing their CL/EL
configuration in their block proposal graffiti. While block proposal
is a rare event and validators can easily switch their CL/ELs between
proposals, we still think that this is an okay approximate signal.

## Combining local and global strategies for full coverage:

It's difficult to detect a lower market share client with a global
strategy. We therefore recommend to use low market share clients with
local strategies and detect high-market share client forks with global
strategies. Installing all <20% CL/ELs (and assuming no unique pairing
bugs) requires three nodes.

## Further work

This document is intended for review by validator implementation
authors and early feedback. Once this is in, implementing local
strategies in a reverse beacon API proxy is the next step.

<!--
### Strategy: Force a higher threshold for attestation data

Assume that in an incident, a minority client with a 10\% share forks at slot 5. After that slot, the attestation data of the minority side will have beacon_block_votes that are in conflict with the majority. A node should be able to see the conflicting attestation data on the gossip network. Some of those attestations might make it into blocks, because there is no validity requirement on the beacon_block_root.

This strategy could be implemented using a reverse proxy by having the proxy recalculate the attestation data from the blocks. Using raw attestation data and redoing the calculation


## Actual algorithm Lazy verify

Our strategy has two states:
* Optimistic
* Pessimistic

When a request for the attestation_data endpoint comes in, we query
all backends with the same request parameters. If we are in
"Optimistic" we reply to the requestor with the first response that we
get from a backend. If we are in pessimistic mode, we wait for all
backends to respond, in which case we only forward the response when
all nodes responded with the same result. If all nodes responded with
the same result, we switch to optimistic for the next slot.

Generally we fail closed if results are missing. However, if we have
seen all nodes vote for the same source epoch, we fail open up up to
slot 31. During slot 31, we require that all backend nodes respond and
agree on the beacon_block_root value.

## Ethereum consensus changes:

Lagged attestation target.

-->