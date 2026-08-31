# --
# OTOBO is a web-based ticketing system for service organisations.
# --
# Copyright (C) 2001-2020 OTRS AG, https://otrs.com/
# Copyright (C) 2019-2026 Rother OSS GmbH, https://otobo.io/
# --
# This program is free software: you can redistribute it and/or modify it under
# the terms of the GNU General Public License as published by the Free Software
# Foundation, either version 3 of the License, or (at your option) any later version.
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
# FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.
# --

package Kernel::Language::de_AgentTicketFormDraftReview;

use strict;
use warnings;
use utf8;

sub Data {
    my $Self = shift;

    # Perl Module: Kernel/Modules/AgentTicketFormDraftEdit.pm
    $Self->{Translation}->{'Need TicketID and FormDraftID!'} = 'Benötige TicketID und FormDraftID!';

    # Perl Module: Kernel/Modules/AgentTicketZoom.pm
    $Self->{Translation}->{'Edit draft'} = 'Entwurf bearbeiten';
    $Self->{Translation}->{'View draft'} = 'Entwurf ansehen';

    # SysConfig
    $Self->{Translation}->{'Edit or view form drafts for tickets.'} = '';
    $Self->{Translation}->{'Form Draft Edit'} = '';
    $Self->{Translation}->{'Required permissions to use the draft edit screen in the agent interface.'} =
        '';


    push @{ $Self->{JavaScriptStrings} // [] }, (
    );

}

1;
