#! /usr/bin/env python3

import argparse
import os
import json

class TestResult:
    def __init__(self, case, behavior):
        self.case = case
        self.behavior = behavior

    def __str__(self):
        return f"Case {self.case}: {self.behavior}"

def check_test_results(folder_path):
    test_results = []
    for filename in os.listdir(folder_path):

        if filename == "index.json":
            continue
        if filename.endswith('.json'):
            file_path = os.path.join(folder_path, filename)
            try:
                with open(file_path, 'r') as file:
                    data = json.load(file)
                    case = data["case"]
                    behavior = data["behavior"] 
                    test_results.append(TestResult(case, behavior))
            except Exception as e:
                print(f"Error reading {filename}: {e}")

    return test_results

def check(folder_path):
    test_results: list[TestResult] = check_test_results(folder_path)
    print(f"Total result count: {len(test_results)}")
    sorted_results = sorted(test_results, key=lambda x: x.case)
    test_pass = True
    for result in sorted_results:
        test_pass = test_pass and (result.behavior == "OK" or result.behavior == "NON-STRICT" or result.behavior == "INFORMATIONAL")
        print(result)
    print("Tests passed ✅" if test_pass else "Tests failed ❌")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument('-p', "--path", required=True, type=str, help='Path to the folder containing rseult JSON files')
    
    # Parse the arguments
    args = parser.parse_args()
    check(args.path)