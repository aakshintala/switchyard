# Switchyard

Switchyard coordinates ticket sessions and their delegated code-writing work.

## Language

### Lane

A ticket session: the sub-orchestrator that takes one ticket through `implement`, from preflight to merge.
_Avoid_: using “lane” for a delegate job.

### Build job

A delegate job (`delegate run`) a lane starts to write code from a lane brief (`skills/planning/briefs/lane.md`); it does not delegate further.
