# AI security platform: target side

The target side of the [AI security platform](https://github.com/sindredg/ai-security-platform): the network the platform investigates, and from milestone 4 the NetBox service, its consumer, and the seeded weaknesses.

The platform's AI workers propose changes to this repository. They never get a credential that writes to the platform repository, so the targets live here, apart from the controls that contain the workers ([ADR 0024](https://github.com/sindredg/ai-security-platform/blob/main/docs/decisions/0024-the-targets-in-their-own-repository-and-signed-commits.md)).

## What is here

| Path | What it holds |
| --- | --- |
| [`infra/targets/`](infra/targets/) | Terraform for the target network in Poland Central: one virtual network, four subnets, a security group each, and the target side of the peering to the platform |
| [`.github/`](.github/) | The pipeline, the signature check, and the key it accepts |

The target root uses the platform's shared network module, pinned to one commit of the platform repository. A change to the module reaches this side only when that pin moves.

The resource group, the state account, the target deployment identity, and the policy that refuses public addresses are made by the platform repository's bootstrap root. So are the rules on the platform side that keep the AI worker away from this network. Moving the target root here does not move them.

## Documentation

The design, the decisions, the checks, and the procedures stay in the platform repository:

- [Architecture](https://github.com/sindredg/ai-security-platform/blob/main/docs/architecture.md), including the address plan.
- [Network foundation runbook](https://github.com/sindredg/ai-security-platform/blob/main/docs/runbooks/network-foundation.md), which applies this root.
- [Repository settings runbook](https://github.com/sindredg/ai-security-platform/blob/main/docs/runbooks/repository-settings.md), which sets up this repository's rulesets.
- [Roadmap](https://github.com/sindredg/ai-security-platform/blob/main/docs/roadmap.md#status), which holds the status.

## License

[MIT](LICENSE).
