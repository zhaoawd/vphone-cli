#!/usr/bin/env python3
"""B37 运行路径预检入口；本批次仅允许 --check。"""
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[3]))
from t08_workspace import offline_runtime_entrypoint

if __name__ == '__main__':
    offline_runtime_entrypoint(__file__)
