DEPRECATED
==========

Use [device-mapper-test-suite](https://github.com/jthornber/device-mapper-test-suite) instead.


Prerequisites
=============

Test suite for device-mapper thin provisioning targets.  Uses Ruby
1.8.x.

You need a program called 'thin_repair' in your path.  This hasn't
been released yet, so just sym link it to /bin/true.

You also need dt in your path.

And aio_stress (http://fsbench.filesystems.org/bench/aio-stress.c).

And blktrace.

And bonnie++.

Running
=======

Edit config.rb, adding suitable entries for you test machine.
Check things are ok with a dry run:

     ./run_tests

Once you're happy you can set the env var THIN_TESTS and run it for
real:

     export THIN_TESTS=EXECUTE
     ./run_tests
   
You can select subsets of the tests via the test suite class, methods
or tags, for more info:

    ./run_tests --help

Examples,

Run all tests that have been tagged as quick:
    ./run_tests -T quick

Run all tests that have been tagged with some sort of target:
    ./run_tests -T /_target$/

Run all tests that have 'resize' in their name:
    ./run_tests -n /resize/

Run all tests in the MultiplePoolTests suite:
    ./run_tests -t MultiplePoolTests


Reports
=======

After you run some tests you can view the results and logs by pointing
your browser at reports/index.html.

If you wish to quickly serve these reports on port 8080 for access
from another machine.

   ./serve_reports


Udev
====

You may find that udev interferes with your tests.  The typical
symptom is test scripts being unable to remove devices (because udev
has it open).  The test suite does retry removal after a pause, which
avoids most cases of this.

One way to disable udev is:

  mv /lib/udev/rules.d/80-udisks.rules /lib/udev/rules.d/80-udisks.rules.dieudevdie
