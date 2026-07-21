import assert from 'node:assert/strict';
import test from 'node:test';
import { smartYardTokenCandidates } from '../src/services/smartYardTokenCompatibility.js';

test('keeps the received token as the first validation candidate', () => {
  assert.deepEqual(smartYardTokenCandidates('m1.example-token'), ['m1.example-token']);
});

test('adds the original SmartYard recPrepare token without the 100 prefix', () => {
  assert.deepEqual(
    smartYardTokenCandidates('100m1.example-token'),
    ['100m1.example-token', 'm1.example-token']
  );
});

test('supports prefixed already-issued camera tokens', () => {
  const token = 'eyJjYW1lcmFfaWQiOiJjYW1lcmEifQ.signature';
  assert.deepEqual(smartYardTokenCandidates(`100${token}`), [`100${token}`, token]);
});

test('does not create an empty fallback for the prefix alone', () => {
  assert.deepEqual(smartYardTokenCandidates('100'), ['100']);
});

test('trims surrounding whitespace and ignores empty input', () => {
  assert.deepEqual(smartYardTokenCandidates('  m1.example-token  '), ['m1.example-token']);
  assert.deepEqual(smartYardTokenCandidates('   '), []);
});
