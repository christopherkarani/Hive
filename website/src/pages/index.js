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
    label: 'Agent Loop',
    code: `Workflow<Schema> {
    ModelTurn("chat", model: "claude-sonnet-4-5-20250929", messages: [
        HiveChatMessage(id: "u1", role: .user, content: "Weather in SF?")
    ])
    .tools(.environment)
    .agentLoop()
    .writes(to: Schema.answer)
    .start()
}`,
  },
  {
    label: 'Branching',
    code: `Workflow<Schema> {
    Node("classify") { input in
        let text = try input.store.get(Schema.text)
        Effects { Set(Schema.category, classify(text)); UseGraphEdges() }
    }.start()

    Node("respond")  { _ in Effects { End() } }
    Node("escalate") { _ in Effects { End() } }

    Branch(from: "classify") {
        Branch.case(name: "urgent", when: {
            (try? $0.get(Schema.category)) == "urgent"
        }) { GoTo("escalate") }
        Branch.default { GoTo("respond") }
    }
}`,
  },
  {
    label: 'Fan-Out + Join + Interrupt',
    code: `Workflow<Schema> {
    Node("dispatch") { _ in
        Effects {
            SpawnEach(["a", "b", "c"], node: "worker") { item in
                var local = HiveTaskLocalStore<Schema>.empty
                try local.set(Schema.item, item)
                return local
            }
            End()
        }
    }.start()

    Node("worker") { input in
        let item = try input.store.get(Schema.item)
        Effects { Append(Schema.results, elements: [item.uppercased()]); End() }
    }

    Node("review") { _ in Effects { Interrupt("Approve results?") } }
    Node("done")   { _ in Effects { End() } }

    Join(parents: ["worker"], to: "review")
    Edge("review", to: "done")
}`,
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
        Expressive DSL for complex agent workflows
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
      title={`${siteConfig.title} — Deterministic Agent Workflows for Swift`}
      description="LangGraph for Swift. Build AI agent workflows that produce byte-identical output on every run."
    >
      <HeroBanner />
      <main>
        <div className={styles.section}>
          <div className="container">
            <h2 className={styles.sectionTitle}>Why Hive?</h2>
            <p className={styles.sectionSubtitle}>
              Everything you need to build production agent workflows in Swift
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
