import React from 'react';

const rows = [
  {
    feature: 'Deterministic execution',
    hive: 'Superstep ordering by node ID. Identical traces every run.',
    langgraph: 'Depends on implementation. No structural guarantee.',
    scratch: 'You build and maintain it yourself.',
  },
  {
    feature: 'Type safety',
    hive: 'HiveSchema with typed channels, reducers, codecs.',
    langgraph: 'Runtime dicts. Errors at execution time.',
    scratch: 'Whatever you enforce manually.',
  },
  {
    feature: 'Concurrency model',
    hive: 'Swift actors + Sendable. Data races are compile errors.',
    langgraph: 'GIL + threads. Race conditions are runtime surprises.',
    scratch: 'Hope and prayer.',
  },
  {
    feature: 'Interrupt / Resume',
    hive: 'Typed payloads. Checkpoint includes frontier + join barriers + store.',
    langgraph: 'Checkpoint support varies.',
    scratch: 'Significant custom work.',
  },
  {
    feature: 'Fan-out / Join',
    hive: 'SpawnEach + Join with bitset barriers. Deterministic merge.',
    langgraph: 'Possible but manual wiring.',
    scratch: 'Graph theory homework.',
  },
  {
    feature: 'On-device inference',
    hive: 'Native support. Route between on-device and cloud models.',
    langgraph: 'Python-only. No on-device story.',
    scratch: 'Depends on your stack.',
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
            <th>LangGraph (Python)</th>
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
