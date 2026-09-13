#!/usr/bin/env python3
"""Run the pinned, unmodified contract harness with this port's shim registration."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser()
p.add_argument('--contract', required=True, type=Path)
p.add_argument('--executable', default=str(ROOT/'.build/debug/lm15-vet'))
args, rest = p.parse_known_args()
contract = args.contract.resolve()
pin = (ROOT/'CONTRACT_PIN').read_text().strip()
head = subprocess.check_output(['git','-C',str(contract),'rev-parse','HEAD'],text=True).strip()
if head != pin: raise SystemExit(f'Contract must be at {pin}, found {head}')
if subprocess.check_output(['git','-C',str(contract),'status','--porcelain'],text=True):
    raise SystemExit('Contract checkout must be clean; use a separate pinned checkout')
spec = importlib.util.spec_from_file_location('lm15_contract_check', contract/'harness/check.py')
module = importlib.util.module_from_spec(spec)
import sys
sys.modules[spec.name] = module
spec.loader.exec_module(module)
with tempfile.TemporaryDirectory(prefix='lm15-swift-harness-') as td:
    registry = Path(td)/'shims.json'
    registry.write_text(json.dumps({'swift':{'cwd':str(ROOT),'command':[args.executable]}}))
    module.SHIMS_FILE = registry
    raise SystemExit(module.main(['--shim','swift','--report-dir',str(ROOT/'tmp/reports'),*rest]))
