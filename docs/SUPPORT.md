# What is supported, and what that word means here

This is a spare-time repository built around one laptop. It is worth being
plain about what that does and does not buy you, so nobody waits on something
that is not coming.

## The short version

| | |
|---|---|
| Machines actually tested here | **one**: a HONOR MagicBook Pro 14 2026, `ZQC-P` |
| Machines recognised | fourteen profiles across twelve product codes, [docs/hardware/](hardware/) |
| Response time | best effort. Days, sometimes weeks |
| Guarantee | none. See [LICENSE](../LICENSE) |
| Cost | nothing, in either direction |

## Where to take a question

| You want to | Go to |
|---|---|
| report something in this repository that does not work | the **Bug report** issue template |
| add a machine, or fill in a profile | the **Hardware dump for a new model** template, and [ADDING-A-MODEL.md](ADDING-A-MODEL.md) |
| ask what to test on a model nobody here owns | [TESTING.md](TESTING.md) |
| report a security problem | [SECURITY.md](../SECURITY.md), not a public issue |
| ask about HONOR's warranty, BIOS updates or hardware faults | HONOR. Nothing here is affiliated with them |

Please do not open an issue asking whether a model will be supported. The
answer is in [docs/hardware/](hardware/) and it is the same for all of them:
as soon as somebody with that laptop sends a dump.

## What "supported" means per status

The word is doing a lot of work and each profile says which sense it means.

| Status | What it means | What you should expect |
|---|---|---|
| **verified** | the fixes were run on that machine here | it should work; if it does not, that is a bug and worth reporting |
| **reported** | somebody ran something on one, in another project | the values are real, the combination is untested. Try it, tell us what happened |
| **probed** | the device ids come from a hardware probe. No fix was tried | detection will recognise your machine and most fixes will refuse. That refusal is information |
| **draft** | model and platform only | as above, with less to go on |

Only `verified` unlocks fixes carrying model-specific constants. On everything
else `ALLOW_UNVERIFIED=1` runs the subset that reads its inputs off the running
machine, and refuses the rest by name.

## What this repository will not do

* **Support discrete NVIDIA GPUs.** The HUNTER machines are in scope for their
  integrated side. The proprietary driver, PRIME and graphics switching are
  somebody else's problem and better solved by your distribution.
* **Ship another machine's firmware to you unchecked.** `acpi-override`
  installs a table taken from one specific unit. Before it writes anything the
  installer reads your machine's own `I2C_DEVT` table and refuses unless the
  md5 matches the stock one on record. That happens to cover two models, because
  ZQC-P and XWC-P ship the identical table; anything else gets a refusal naming
  both md5s. If yours differs, rebuild it from your own tables:
  [RESEARCH.md](RESEARCH.md).
* **Guess a value.** A profile field left `unknown` is a deliberate statement.
  A wrong EC offset or backlight floor is worse than a missing one, because the
  installers act on what is written.
* **Carry a fix that is upstream.** As things land the directories here get
  deleted; [patch/README.md](../patch/README.md#upstream) tracks where each one
  stands. If you are about to write a fix, check there first — three of them
  have already been merged into the kernel.

## If you want to help

In descending order of how much difference it makes:

1. **Run `tools/collect-hwinfo.sh` and `tools/dump-acpi.sh` on any HONOR
   MagicBook and attach the result to [issue #11](https://github.com/rs0x29a/Linux-on-HONOR-MagicBook-14-Pro-2026-AI_ZQC-P_M1010/issues/11), or to a model issue
   linked from it.** Two read-only commands. A
   single hardware probe was enough to fill in an entire model's inventory
   here. There is still no probe of the reference machine on
   linux-hardware.org, so even that one is worth doing.
2. **Answer the questions in [TESTING.md](TESTING.md)** on a model that is not
   `verified`. "Works out of the box" is a genuinely useful answer and is the
   one most often missing.
3. **Send the fixes upstream.** Several are three lines and nobody has posted
   them. [patch/README.md](../patch/README.md#upstream) lists which, including
   one somebody else is already sending, so you do not duplicate their work.
4. **Correct something here.** If a claim on a page is wrong, saying so with a
   source is worth more than a polite silence. Several pages exist only because
   an earlier version of them was wrong.
