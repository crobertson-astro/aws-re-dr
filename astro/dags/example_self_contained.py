from airflow.sdk import dag, task
from pendulum import datetime


@dag(
    start_date=datetime(2026, 7, 9),
    schedule=None,
    catchup=False,
    tags=["example", "gitdagbundle"],
)
def example_self_contained():
    @task
    def say_hello() -> str:
        message = "GitDagBundle self-contained DAG loaded successfully."
        print(message)
        return message

    say_hello()


example_self_contained()
