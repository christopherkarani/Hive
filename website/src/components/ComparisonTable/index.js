import React from 'react';

const rows = [
  {
    feature: 'Deterministic execution',
    hive: 'Superstep ordering by node ID. Identical traces every run.',
    langgraph: 'Usually runtime-dependent ordering.',
    scratch: 'You build and maintain it yourself.',
  },
  {
    feature: 'Type safety',
    hive: 'HiveSchema with typed channels, reducers, codecs.',
    langgraph: 'Often dictionary-based state.',
    scratch: 'Whatever you enforce manually.',
  },
  {
    feature: 'Concurrency model',
    hive: 'Swift actors + Sendable. Data races are compile errors.',
    langgraph: 'Depends on the host runtime.',
    scratch: 'You own scheduling and isolation.',
  },
  {
    feature: 'Interrupt / Resume',
    hive: 'Typed payloads. Checkpoint includes frontier + join barriers + store.',
    langgraph: 'Support depends on the framework and adapter.',
    scratch: 'Significant custom work.',
  },
  {
    feature: 'Fan-out / Join',
    hive: 'SpawnEach + Join with bitset barriers. Deterministic merge.',
    langgraph: 'Possible but manual wiring.',
    scratch: 'You implement barriers yourself.',
  },
  {
    feature: 'Runtime surface',
    hive: 'Core graph primitives only. No DSL, model, tool, or RAG APIs.',
    langgraph: 'Often combines runtime and higher-level orchestration.',
    scratch: 'You decide every boundary.',
  },
  {
    feature: 'Golden testing',
    hive: 'Assert exact event sequences. Immutable graph JSON.',
    langgraph: 'Snapshot testing possible but non-deterministic.',
    scratch: 'Not practical without determinism.',
  },
];

export default function ComparisonTable() {
  return (
    <div style={{ overflowX: 'auto' }}>
      <table>
        <thead>
          <tr>
            <th></th>
            <th>Hive</th>
            <th>Other graph frameworks</th>
            <th>Building from scratch</th>
          </tr>
        </thead>
        <tbody>
          {rows.map((row, idx) => (
            <tr key={idx}>
              <td>
                <strong>{row.feature}</strong>
              </td>
              <td>{row.hive}</td>
              <td>{row.langgraph}</td>
              <td>{row.scratch}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
