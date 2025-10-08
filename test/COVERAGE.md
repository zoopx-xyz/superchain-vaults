# Coverage summary

Generated: 2025-10-08
Commit: 69ec534 (main)

This project uses Foundry’s coverage instrumentation to produce LCOV output. For accuracy, coverage runs exclude deployment scripts and disable optimizer/viaIR (as Foundry does automatically during coverage).

## Overall coverage (all files)

- Lines: 81.39% (1207/1483)
- Statements: 79.56% (1257/1580)
- Branches: 60.00% (150/250)
- Functions: 71.83% (255/355)

## Contracts-only coverage (contracts/)

- Overall (average of Lines, Branches, Functions): 87.79%

- Lines: 94.27% (856/908)
- Branches: 81.44% (136/167)
- Functions: 87.65% (142/162)

Contracts-only branch coverage meets the ≥80% target via tests-only changes.

## How to re-run locally

Use the coverage profile to generate LCOV and a human summary. Scripts are excluded to avoid stack-too-deep and preserve accurate mapping.

```bash
FOUNDRY_PROFILE=coverage forge coverage --report lcov --report summary
```

Optionally, compute contracts-only branch coverage directly from `lcov.info` (BRH/BRF restricted to paths under `contracts/`):

```bash
python3 - << 'PY'
from pathlib import Path
brh=brf=lnh=lnf=stmh=stmf=fnh=fnf=0
with Path('lcov.info').open() as f:
    in_contract=False
    for line in f:
        if line.startswith('SF:'):
            p=line.strip()[3:]
            in_contract = p.startswith('contracts/') or '/contracts/' in p
        elif in_contract and line.startswith('BRH:'):
            brh += int(line.split(':')[1])
        elif in_contract and line.startswith('BRF:'):
            brf += int(line.split(':')[1])
        elif in_contract and line.startswith('LH:'):
            lnh += int(line.split(':')[1])
        elif in_contract and line.startswith('LF:'):
            lnf += int(line.split(':')[1])
        elif in_contract and line.startswith('FNH:'):
            fnh += int(line.split(':')[1])
        elif in_contract and line.startswith('FNF:'):
            fnf += int(line.split(':')[1])
print('contracts-only branches:', f"{brh}/{brf} = {100.0*brh/brf:.2f}%")
print('contracts-only lines:', f"{lnh}/{lnf} = {100.0*lnh/lnf:.2f}%")
print('contracts-only funcs:', f"{fnh}/{fnf} = {100.0*fnh/fnf:.2f}%")
PY
```

## Notes

- Foundry disables optimizer and viaIR during coverage to improve instrumentation accuracy;
  if you see stack-too-deep errors, exclude or stub scripts during coverage (already applied here).
- LCOV report is written to `lcov.info`; the tabular summary appears in the coverage output.
