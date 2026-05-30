#!/usr/bin/env python3
"""
Project Lazarus verification kernel.

This is a deliberately bounded equivalence engine. It proves equality for a
small expression IR over finite integer domains, returns counterexamples when
it can find them, and returns INCONCLUSIVE instead of pretending to prove
arbitrary legacy programs.
"""

from __future__ import annotations

import dataclasses
import itertools
import json
from typing import Any, Literal


Verdict = Literal["EQUIVALENT", "COUNTEREXAMPLE", "INCONCLUSIVE", "INVALID_INPUT"]
OPS = {"add", "sub", "mul", "neg", "min", "max", "abs"}


@dataclasses.dataclass(frozen=True)
class EquivalenceReport:
    verdict: Verdict
    variables: tuple[str, ...]
    cases_checked: int
    counterexample: dict[str, int] | None = None
    legacy_value: int | None = None
    refactored_value: int | None = None
    reason: str | None = None

    def to_json(self) -> str:
        return json.dumps(dataclasses.asdict(self), ensure_ascii=False, sort_keys=True)


class Expr:
    def eval(self, env: dict[str, int]) -> int:
        raise NotImplementedError

    def vars(self) -> set[str]:
        raise NotImplementedError

    def normalize(self) -> "Expr":
        return self


@dataclasses.dataclass(frozen=True)
class Const(Expr):
    value: int

    def eval(self, env: dict[str, int]) -> int:
        return self.value

    def vars(self) -> set[str]:
        return set()


@dataclasses.dataclass(frozen=True)
class Var(Expr):
    name: str

    def eval(self, env: dict[str, int]) -> int:
        return env[self.name]

    def vars(self) -> set[str]:
        return {self.name}


@dataclasses.dataclass(frozen=True)
class Op(Expr):
    op: str
    args: tuple[Expr, ...]

    def eval(self, env: dict[str, int]) -> int:
        values = [arg.eval(env) for arg in self.args]
        if self.op == "add":
            return values[0] + values[1]
        if self.op == "sub":
            return values[0] - values[1]
        if self.op == "mul":
            return values[0] * values[1]
        if self.op == "neg":
            return -values[0]
        if self.op == "min":
            return min(values[0], values[1])
        if self.op == "max":
            return max(values[0], values[1])
        if self.op == "abs":
            return abs(values[0])
        raise ValueError(f"unsupported op: {self.op}")

    def vars(self) -> set[str]:
        names: set[str] = set()
        for arg in self.args:
            names.update(arg.vars())
        return names

    def normalize(self) -> Expr:
        normalized = tuple(arg.normalize() for arg in self.args)
        if all(isinstance(arg, Const) for arg in normalized):
            return Const(Op(self.op, normalized).eval({}))
        if self.op == "add":
            left, right = normalized
            if left == Const(0):
                return right
            if right == Const(0):
                return left
            return Op("add", tuple(sorted(normalized, key=repr)))
        if self.op == "mul":
            left, right = normalized
            if left == Const(0) or right == Const(0):
                return Const(0)
            if left == Const(1):
                return right
            if right == Const(1):
                return left
            return Op("mul", tuple(sorted(normalized, key=repr)))
        if self.op == "sub" and normalized[1] == Const(0):
            return normalized[0]
        if self.op == "neg" and isinstance(normalized[0], Op) and normalized[0].op == "neg":
            return normalized[0].args[0]
        return Op(self.op, normalized)


def parse_expr(value: Any) -> Expr:
    if isinstance(value, int) and not isinstance(value, bool):
        return Const(value)
    if isinstance(value, str):
        if not value.isidentifier():
            raise ValueError(f"invalid variable name: {value!r}")
        return Var(value)
    if not isinstance(value, dict):
        raise ValueError("expression must be int, variable string, or object")
    if "const" in value:
        const = value["const"]
        if not isinstance(const, int) or isinstance(const, bool):
            raise ValueError("const must be an integer")
        return Const(const)
    if "var" in value:
        name = value["var"]
        if not isinstance(name, str) or not name.isidentifier():
            raise ValueError("var must be a valid identifier")
        return Var(name)
    op = value.get("op")
    args = value.get("args")
    if op not in OPS:
        raise ValueError(f"unsupported op: {op!r}")
    if not isinstance(args, list):
        raise ValueError("op expression requires args list")
    expected_arity = 1 if op in {"neg", "abs"} else 2
    if len(args) != expected_arity:
        raise ValueError(f"{op} expects {expected_arity} args")
    return Op(op, tuple(parse_expr(arg) for arg in args)).normalize()


def prove_equivalent(
    legacy: Any,
    refactored: Any,
    variable_domains: dict[str, list[int]] | None = None,
    max_cases: int = 100_000,
) -> EquivalenceReport:
    try:
        left = parse_expr(legacy).normalize()
        right = parse_expr(refactored).normalize()
    except Exception as exc:
        return EquivalenceReport(
            verdict="INVALID_INPUT",
            variables=(),
            cases_checked=0,
            reason=f"{type(exc).__name__}: {exc}",
        )

    variables = tuple(sorted(left.vars() | right.vars()))
    if left == right:
        return EquivalenceReport(
            verdict="EQUIVALENT",
            variables=variables,
            cases_checked=0,
            reason="normalized expressions are identical",
        )

    domains = variable_domains or {name: list(range(-16, 17)) for name in variables}
    for name in variables:
        if name not in domains or not domains[name]:
            return EquivalenceReport(
                verdict="INVALID_INPUT",
                variables=variables,
                cases_checked=0,
                reason=f"missing finite domain for variable {name}",
            )
    total_cases = 1
    for name in variables:
        total_cases *= len(domains[name])
    if total_cases > max_cases:
        return EquivalenceReport(
            verdict="INCONCLUSIVE",
            variables=variables,
            cases_checked=0,
            reason=f"case space {total_cases} exceeds max_cases {max_cases}",
        )

    cases_checked = 0
    for values in itertools.product(*(domains[name] for name in variables)):
        env = dict(zip(variables, values))
        cases_checked += 1
        left_value = left.eval(env)
        right_value = right.eval(env)
        if left_value != right_value:
            return EquivalenceReport(
                verdict="COUNTEREXAMPLE",
                variables=variables,
                cases_checked=cases_checked,
                counterexample=env,
                legacy_value=left_value,
                refactored_value=right_value,
                reason="outputs differ for the same input assignment",
            )

    return EquivalenceReport(
        verdict="EQUIVALENT",
        variables=variables,
        cases_checked=cases_checked,
        reason="all finite-domain cases matched",
    )


def _selftest() -> None:
    same = prove_equivalent(
        {"op": "add", "args": ["x", {"const": 0}]},
        "x",
        {"x": [-1, 0, 1]},
    )
    assert same.verdict == "EQUIVALENT", same

    different = prove_equivalent(
        {"op": "add", "args": ["x", 1]},
        "x",
        {"x": [-1, 0, 1]},
    )
    assert different.verdict == "COUNTEREXAMPLE", different

    too_large = prove_equivalent("x", "x", {"x": list(range(200_000))}, max_cases=10)
    assert too_large.verdict == "EQUIVALENT", too_large
    print("VerificationKernel selftest passed")


if __name__ == "__main__":
    _selftest()
