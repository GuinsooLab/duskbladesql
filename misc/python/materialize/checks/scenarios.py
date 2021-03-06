# Copyright Materialize, Inc. and contributors. All rights reserved.
#
# Use of this software is governed by the Business Source License
# included in the LICENSE file at the root of this repository.
#
# As of the Change Date specified in that file, in accordance with
# the Business Source License, use of this software will be governed
# by the Apache License, Version 2.0.
# Copyright Materialize, Inc. and contributors. All rights reserved.
#
# Use of this software is governed by the Business Source License
# included in the LICENSE file at the root of this repository.
#
# As of the Change Date specified in that file, in accordance with
# the Business Source License, use of this software will be governed
# by the Apache License, Version 2.0.

from typing import List, Type

from materialize.checks.actions import Action
from materialize.checks.actions import (
    DropCreateDefaultReplica as DropCreateDefaultReplicaAction,
)
from materialize.checks.actions import Initialize, KillComputed, Manipulate
from materialize.checks.actions import RestartMz as RestartMzAction
from materialize.checks.actions import StartComputed, StartMz, UseComputed, Validate
from materialize.checks.checks import Check
from materialize.mzcompose import Composition


class Scenario:
    def __init__(self, checks: List[Type[Check]]) -> None:
        self.checks = checks

    def actions(self) -> List[Action]:
        assert False

    def run(self, c: Composition) -> None:
        for action in self.actions():
            action.execute(c)


class NoRestartNoUpgrade(Scenario):
    def actions(self) -> List[Action]:
        return [
            StartMz(),
            Initialize(self.checks),
            Manipulate(self.checks, phase=1),
            Manipulate(self.checks, phase=2),
            Validate(self.checks),
        ]


class RestartMz(Scenario):
    def actions(self) -> List[Action]:
        return [
            StartMz(),
            Initialize(self.checks),
            Manipulate(self.checks, phase=1),
            RestartMzAction(),
            Manipulate(self.checks, phase=2),
            Validate(self.checks),
        ]


class DropCreateDefaultReplica(Scenario):
    def actions(self) -> List[Action]:
        return [
            StartMz(),
            Initialize(self.checks),
            Manipulate(self.checks, phase=1),
            DropCreateDefaultReplicaAction(),
            Manipulate(self.checks, phase=2),
            Validate(self.checks),
        ]


class RestartComputed(Scenario):
    def actions(self) -> List[Action]:
        return [
            StartMz(),
            StartComputed(),
            UseComputed(),
            Initialize(self.checks),
            KillComputed(),
            StartComputed(),
            Manipulate(self.checks, phase=1),
            KillComputed(),
            StartComputed(),
            Manipulate(self.checks, phase=2),
            KillComputed(),
            StartComputed(),
            Validate(self.checks),
        ]
