"""Create the three source databases and warehouse tables; no sample rows are inserted."""
from boa_etl.database import create_schemas


def main():
    create_schemas()


if __name__ == "__main__":
    main()

