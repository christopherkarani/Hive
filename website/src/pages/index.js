import React, { useState } from 'react';
import clsx from 'clsx';
import Link from '@docusaurus/Link';
import useDocusaurusContext from '@docusaurus/useDocusaurusContext';
import Layout from '@theme/Layout';
import CodeBlock from '@theme/CodeBlock';
import HomepageFeatures from '@site/src/components/HomepageFeatures';
import ComparisonTable from '@site/src/components/ComparisonTable';
import styles from './index.module.css';

const codeExamples = [
  {
    label: 'Static Edge',
    code: `var builder = HiveGraphBuilder<Schema>(start: [HiveNodeID("load")])

builder.addNode(HiveNodeID("load")) { input in
        let text = try input.store.get(Schema.input)
        return HiveNodeOutput(
            writes: [AnyHiveWrite(Schema.normalized, text.lowercased())],
            next: .useGraphEdges
        )
    }

builder.addNode(HiveNodeID("rank")) { input in
        let text = try input.store.get(Schema.normalized)
        return HiveNodeOutput(
            writes: [AnyHiveWrite(Schema.score, score(text))],
            next: .end
        )
    }

builder.addEdge(from: HiveNodeID("load"), to: HiveNodeID("rank"))
let graph = try builder.compile()`,
  },
  {
    label: 'Branching',
    code: `var builder = HiveGraphBuilder<Schema>(start: [HiveNodeID("classify")])

builder.addNode(HiveNodeID("classify")) { input in
        let text = try input.store.get(Schema.text)
        return HiveNodeOutput(
            writes: [AnyHiveWrite(Schema.category, classify(text))],
            next: .useGraphEdges
        )
    }

builder.addRouter(from: HiveNodeID("classify")) { store in
    switch try store.get(Schema.category) {
    case "urgent": return .to([HiveNodeID("escalate")])
    default: return .to([HiveNodeID("respond")])
    }
}

builder.addNode(HiveNodeID("respond"))  { _ in HiveNodeOutput(next: .end) }
builder.addNode(HiveNodeID("escalate")) { _ in HiveNodeOutput(next: .end) }
let graph = try builder.compile()`,
  },
  {
    label: 'Fan-Out + Join + Interrupt',
    code: `var builder = HiveGraphBuilder<Schema>(start: [HiveNodeID("dispatch")])

builder.addNode(HiveNodeID("dispatch")) { _ in
        let apple = try makeTaskLocal(item: "apple")
        let banana = try makeTaskLocal(item: "banana")
        HiveNodeOutput(
            spawn: [
                HiveTaskSeed(nodeID: HiveNodeID("workerA"), local: apple),
                HiveTaskSeed(nodeID: HiveNodeID("workerB"), local: banana)
            ],
            next: .end
        )
    }

builder.addNode(HiveNodeID("workerA")) { input in
        let item = try input.store.get(Schema.item)
        return HiveNodeOutput(
            writes: [AnyHiveWrite(Schema.results, [item.uppercased()])],
            next: .end
        )
    }

builder.addNode(HiveNodeID("workerB")) { input in
    let item = try input.store.get(Schema.item)
    return HiveNodeOutput(
        writes: [AnyHiveWrite(Schema.results, [item.uppercased()])],
        next: .end
    )
}

builder.addNode(HiveNodeID("review")) { _ in
    HiveNodeOutput(interrupt: HiveInterruptRequest(payload: "approve"))
}

builder.addJoinEdge(
    parents: [HiveNodeID("workerA"), HiveNodeID("workerB")],
    target: HiveNodeID("review")
)

let graph = try builder.compile()`,
  },
];

function HeroBanner() {
  const { siteConfig } = useDocusaurusContext();
  return (
    <header className={styles.heroBanner}>
      <div className="container">
        <div className={styles.badges}>
          <span className={clsx(styles.badge, styles.badgeSwift)}>
            Swift 6.2
          </span>
          <span className={clsx(styles.badge, styles.badgePlatform)}>
            iOS 26+
          </span>
          <span className={clsx(styles.badge, styles.badgePlatform)}>
            macOS 26+
          </span>
          <span className={clsx(styles.badge, styles.badgeLicense)}>MIT</span>
        </div>
        <h1 className={styles.heroTitle}>{siteConfig.title}</h1>
        <p className={styles.heroSubtitle}>{siteConfig.tagline}</p>
        <div className={styles.buttons}>
          <Link
            className="button button--primary button--lg"
            to="/docs/intro"
          >
            Get Started
          </Link>
          <Link
            className="button button--outline button--lg"
            href="https://github.com/christopherkarani/Hive"
          >
            GitHub
          </Link>
        </div>
        <div className={styles.installSnippet}>
          <code>
            .package(url: "https://github.com/christopherkarani/Hive.git",
            from: "1.0.0")
          </code>
        </div>
      </div>
    </header>
  );
}

function CodeExamples() {
  const [active, setActive] = useState(0);
  return (
    <div className={clsx(styles.codeSection, 'container')}>
      <h2 className={styles.sectionTitle}>See It in Action</h2>
      <p className={styles.sectionSubtitle}>
        Explicit graph builder APIs for deterministic runtime behavior
      </p>
      <div className={styles.tabList}>
        {codeExamples.map((example, idx) => (
          <button
            key={idx}
            className={clsx(styles.tab, idx === active && styles.tabActive)}
            onClick={() => setActive(idx)}
          >
            {example.label}
          </button>
        ))}
      </div>
      <div className={styles.codeBlock}>
        <CodeBlock language="swift">{codeExamples[active].code}</CodeBlock>
      </div>
    </div>
  );
}

export default function Home() {
  const { siteConfig } = useDocusaurusContext();
  return (
    <Layout
      title={`${siteConfig.title} — Deterministic Graph Runtime for Swift`}
      description="Build Swift graph runtimes with atomic supersteps, typed state, checkpoints, interrupts, and deterministic replay."
    >
      <HeroBanner />
      <main>
        <div className={styles.section}>
          <div className="container">
            <h2 className={styles.sectionTitle}>Why Hive?</h2>
            <p className={styles.sectionSubtitle}>
              Runtime primitives for production Swift graph execution
            </p>
          </div>
          <HomepageFeatures />
        </div>
        <CodeExamples />
        <div className={clsx(styles.comparisonSection, 'container')}>
          <h2 className={styles.sectionTitle}>How Does Hive Compare?</h2>
          <p className={styles.sectionSubtitle}>
            Purpose-built for Swift with determinism guarantees no other
            framework provides
          </p>
          <ComparisonTable />
        </div>
      </main>
    </Layout>
  );
}
