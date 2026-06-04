from setuptools import setup, find_namespace_packages

setup(
    name="cli-anything-wintermolt",
    version="0.1.0",
    description="CLI-Anything harness for Wintermolt AI agent",
    author="David Clabaugh",
    author_email="david@thefantasticplanet.com",
    license="AGPL-3.0",
    packages=find_namespace_packages(include=["cli_anything.*"]),
    package_data={
        "cli_anything.wintermolt": ["skills/*.md"],
    },
    install_requires=[
        "click>=8.0",
    ],
    entry_points={
        "console_scripts": [
            "cli-anything-wintermolt=cli_anything.wintermolt.wintermolt_cli:cli",
        ],
    },
    python_requires=">=3.9",
    classifiers=[
        "Programming Language :: Python :: 3",
        "License :: OSI Approved :: GNU Affero General Public License v3",
        "Topic :: Software Development :: Libraries :: Application Frameworks",
    ],
)
