# Spoke Notebook - Read API results from lakehouse table
# Called by Pipeline_1 after Hub notebook writes data to lakehouse
# Parameters are passed from the pipeline

# Parameters cell - overridden by Pipeline_1
lakehouse_name = ""   # Lakehouse to read from
table_name = ""       # Table to read

# ---

print(f"Spoke: Reading table '{table_name}' from lakehouse '{lakehouse_name}'")

table_path = f"abfss://{lakehouse_name}@onelake.dfs.fabric.microsoft.com/Tables/{table_name}"

try:
    df = spark.read.format("delta").load(table_path)
    row_count = df.count()
    print(f"Spoke: Successfully loaded {row_count} rows from {lakehouse_name}/{table_name}")
    print(f"\nSchema:")
    df.printSchema()
    print(f"\nData:")
    df.show(20, truncate=False)

    notebookutils.notebook.exit(f"Success: {row_count} rows read from {table_name}")
except Exception as e:
    print(f"Spoke: ERROR reading table - {e}")
    notebookutils.notebook.exit(f"Error: {str(e)}")
