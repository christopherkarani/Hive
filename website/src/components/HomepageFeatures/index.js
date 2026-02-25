import React from 'react';
import styles from './styles.module.css';

const features = [
  {
    icon: '&#x2B21;',
    title: 'Deterministic Execution',
    description:
      'BSP supersteps with lexicographic ordering. Same input produces identical output, event traces, and checkpoint bytes every time.',
  },
  {
    icon: '&#x1F3AF;',
    title: 'Type-Safe Channels',
    description:
      'HiveSchema with typed channels, reducers, and codecs. Errors caught at compile time, not buried in runtime logs.',
  },
  {
    icon: '&#x26A1;',
    title: 'Swift Concurrency',
    description:
      'Built on actors, Sendable, and async/await. Data races are compile errors. No GIL, no runtime surprises.',
  },
  {
    icon: '&#x270B;',
    title: 'Human-in-the-Loop',
    description:
      'Interrupt workflows for approval. Checkpoint full state — store, frontier, join barriers. Resume with typed payloads.',
  },
  {
    icon: '&#x1F500;',
    title: 'Fan-Out & Join',
    description:
      'SpawnEach dispatches parallel workers with task-local state. Join barriers synchronize them. Deterministic merge on completion.',
  },
  {
    icon: '&#x1F916;',
    title: 'Hybrid Inference',
    description:
      'Bounded ReAct agent loops with tool calling and streaming tokens. Route between on-device and cloud models seamlessly.',
  },
];

export default function HomepageFeatures() {
  return (
    <div className={styles.features}>
      {features.map((feature, idx) => (
        <div key={idx} className={styles.featureCard}>
          <div
            className={styles.featureIcon}
            dangerouslySetInnerHTML={{ __html: feature.icon }}
          />
          <div className={styles.featureTitle}>{feature.title}</div>
          <p className={styles.featureDescription}>{feature.description}</p>
        </div>
      ))}
    </div>
  );
}
