FROM python:3.11-slim

# Install any system dependencies you need (example: libpq-dev, etc)
# RUN apt-get update && apt-get install -y ...

# Create a directory for your code
WORKDIR /app

# Copy your script and requirements
COPY tools/plot/requirements.txt /app/
RUN pip install --no-cache-dir -r requirements.txt

COPY tools/plot/plot.py /app/

# Default command: run the script with any arguments
ENTRYPOINT ["python", "plot.py"]
