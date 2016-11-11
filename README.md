# Windows Juju charm for NSClient++

This is a subordinate charm that attaches to any principle charm through a `local-monitors` interface. If there is no `local-monitors` interface on the principle charm, the implicit `juju-info` interface is used for getting general info from the charm.


## Installing, configuring and testing

Assuming you already have a Juju environment already set up and a Windows 2012 R2 machine deployed, download the charm onto a machine that can issue Juju commands, deploy the nagios charm, a windows charm (e.g mssql-express) and the NSClient++ subordinate charm:

    juju deploy nagios
    juju deploy cs:~cloudbaseit/win2012r2/mssql-express
    juju deploy --repository /path/to/charms/directory local:win2012r2/nsclient

Create relations between mssql-express - nsclient and nsclient-nagios:

    juju add-relation mssql-express nsclient
    juju add-relation nsclient:monitors nagios:monitors  (this relation must be made through the 'monitors' interface)


## Flow:

When this charm is deployed, being a subordinate charm, it is added to the Juju environment without being deployed to any node. The actual deployment and install is done when a relation is set between a principle charm and nsclient charm. So after setting a relation with a principle charm, nsclient is deployed on the same node the principle charm is running on.

Ideally, the principle charm should have a 'local-monitors' interface. Through this interface, the principle charm can send the resources Nagios should monitor.

By default, on every relation set, there are 3 fields monitored: CPU usage, Memory Usage and Disk Usage. This fields can not be changed and are automatically added to the monitored node.

When the relation with the Nagios charm is set, NSclient pulls the Nagios server's `private-address` and sets it in the `allowed hosts` of its configuration file. Then, it sends 3 fields through the `monitors` interface to the Nagios server: `target-addres`, `target-id` and `monitors` (ip address, hostname and what to monitor). The `monitors` field contains the default checks + checks sent from the principle charm thorough the `local-monitors` interface.


## config.yaml

Besides the self-explanatory entries in the config, you can also manually add check fields to the monitors.yaml. The `monitors` field accepts a strict input. For more details see `monitors.yaml` section below.


## monitors.yaml

Check requests can be sent from the principle charm to NSClient charm through the `local-monitors` interface, who in turn forwards it to the Nagios charm through the `monitors` interface.

An example of `monitors` field sent through the `local-monitors` interface :

    # this is a monitors yaml
    monitors:
      # inform Nagios that this is a remote check and not a local one.
      remote:
        # define the check type. This version of the charm
        # only supports nrpe checks. Future versions will add other types of checks.
        nrpe:
          # name given by us for the command that will appear in
          # the Nagios webui dashboard (can be arbitrary)
          event_log:
            # the actual command that Nagios will run. In this example the
            # command is 'alias_event_log' that checks the event logs from the principle charms host.
            # Nagios interprets it as 'check_nrpe -H <ipaddress of remote host> -c alias_event_log'
            command: alias_event_log

The alias commands are already predefined in NSClient. We can also give a standard nrpe command. So instead of `command: alias_event_log` we can do `command: CheckEventLog` and we can add `-a` for extra arguments. For more information visit NSClient++ documentation for aliases and Nagios documentation for check_nrpe commands.

Additional checks can also be set through the `monitors` config option:

    juju set nsclient monitors: "monitors:
      remote:
        nrpe:
          event_log:
            command: alias_event_log"

The format is very important. If the formatting of the config is wrong, Nagios charm will complain about this and enter in error state.
