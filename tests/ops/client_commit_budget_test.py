"""What our components commit in a client, per mode (CM, 27 Nov 2026), checked offline against the sources.

Measured with ops/memlab/vmmap.py on the Forge lab client (cp_zmb, at the ready state): 8.3 GB commit, 3.7 GB working set, the same peak; -no-snapshot-entities
8.28 GB (the default, with the snapshot cap, 8.31 GB). 4.8 GB of the commit is the engine's own allocator segments (16/32/64 MB, never touched), not ours.
This test pins the part that is ours:
  - the default client (snapshot only, FE21: cap 2,048 entities per snapshot) reserves no pool of its own: snapshot_only() and what it calls
    (plan_snapshot, snapshot_object_sizes) make no reserve(), VirtualAlloc or _aligned_malloc; only post_unpack's -agent-capacity branch does;
  - the memory that cap adds (server ring, client snapshot objects, client ring) is bounded by a number computed from the constants of
    agent_capacity.hpp, and that bound stays far under what the measurement can see (64 MB).
"""
import os
import re
import unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..'))
CPP = open(os.path.join(ROOT, 'src', 'native', 'agent_capacity.cpp'), encoding='utf-8').read()
HPP = open(os.path.join(ROOT, 'src', 'native', 'agent_capacity.hpp'), encoding='utf-8').read()

ALLOCATORS = re.compile(r'\b(reserve|reserve_code)\s*\(|VirtualAlloc|_aligned_malloc|\bmalloc\s*\(|\bnew\s+\w+\s*\[')


def body(source, signature):
    start = source.index(signature)
    brace = source.index('{', start)
    depth, i = 0, brace
    while True:
        depth += source[i] == '{'
        depth -= source[i] == '}'
        i += 1
        if depth == 0:
            return source[brace:i]


def constant(name, source=HPP):
    m = re.search(r'\b' + name + r'\s*=\s*(0x[0-9A-Fa-f]+|\d+)', source)
    assert m, name
    return int(m.group(1), 0)


class ClientCommitBudget(unittest.TestCase):
    def test_snapshot_only_allocates_nothing(self):
        for signature in ('void snapshot_only() {', 'void plan_snapshot() {', 'void snapshot_object_sizes() {'):
            self.assertIsNone(ALLOCATORS.search(body(CPP, signature)), signature + ' allocates: a snapshot-only client must commit no pool of ours')

    def test_default_path_returns_before_any_pool(self):
        post_unpack = body(CPP, 'void post_unpack() override {')
        branch = post_unpack[:post_unpack.index('const auto parts')]
        self.assertIn('snapshot_only();', branch)
        self.assertIn('return;', branch)
        self.assertIsNone(ALLOCATORS.search(branch))

    def test_snapshot_cap_budget(self):
        self.assertIn('client_ring_per_frame = snapshot_entities', HPP)
        entities, record = constant('snapshot_entities'), constant('entity_record_bytes')
        stock_ring, stock_entities = constant('stock_ring_frame_term'), constant('stock_snapshot_entities')
        ring_term = stock_ring + 3 * (entities - stock_entities)
        server_ring = 16 * (ring_term - stock_ring) * record                                       # 16 frames of the server's entity-state ring
        client_ring = 64 * (entities - constant('stock_client_ring_per_frame')) * record   # at most 64 frames
        objects = 3 * (entities - stock_entities) * record                                          # client snapshot objects (two sites, one more)
        budget = server_ring + client_ring + objects
        self.assertLess(budget, 64 << 20, 'the snapshot cap would commit %.1f MB more than stock' % (budget / 2**20))
        self.assertGreater(budget, 0)


if __name__ == '__main__':
    unittest.main()
