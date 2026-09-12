#!/usr/bin/env python3
# This file is the compatibility shim of the packaging: setuptools reads
# pyproject.toml through the modern backend, but operations teams still carry
# old toolchains and CI images that only speak setup.py. The metadata below is
# a mirror of pyproject.toml by agreement, so the two files must always change
# together; tools/finish.sh runs a parity check against this file.

from setuptools import setup

setup(
    name="aws-cloud-ops",
    version="1.0.0",
    author="Arees Manesia",
    author_email="arees.manesia8@gmail.com",
    description=("Operations toolkit for AWS platform engineers: EOL/EOS "
                 "remediation, large-scale patching, blue/green upgrades, "
                 "drift detection, monitoring."),
    license="Apache-2.0",
    python_requires=">=3.9",
    packages=["cloudops"],
    package_data={"cloudops": ["data/*.json"]},
    include_package_data=True,
    entry_points={
        "console_scripts": ["cloudops=cloudops.cli:main"],
    },
    classifiers=[
        "Development Status :: 5 - Production/Stable",
        "Environment :: Console",
        "Intended Audience :: System Administrators",
        "License :: OSI-Approved :: Apache Software License",
        "Operating System :: POSIX",
        "Programming Language :: Python :: Only",
        "Topic :: System :: Clustering/Monitoring",
        "Topic :: System :: Installation :: Packaging",
    ],
)
