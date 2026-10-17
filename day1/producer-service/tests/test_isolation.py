from src.isolation.inspector import collect_isolation_facts


def test_isolation_facts_include_pid_and_hostname():
    facts = collect_isolation_facts()
    assert isinstance(facts["pid"], int)
    assert facts["pid"] > 0
    assert facts["hostname"]
    assert "namespaces" in facts
