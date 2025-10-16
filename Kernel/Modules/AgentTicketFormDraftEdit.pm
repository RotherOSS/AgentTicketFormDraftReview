# --
# OTOBO is a web-based ticketing system for service organisations.
# --
# Copyright (C) 2001-2020 OTRS AG, https://otrs.com/
# Copyright (C) 2019-2025 Rother OSS GmbH, https://otobo.io/
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

package Kernel::Modules::AgentTicketFormDraftEdit;

use v5.24;
use strict;
use warnings;

# core modules

# CPAN modules

# OTOBO modules
use Kernel::System::VariableCheck qw(:all);
use Kernel::Language              qw(Translatable);
use Mail::Address                 ();

our $ObjectManagerDisabled = 1;

sub new {
    my ( $Type, %Param ) = @_;

    # allocate new hash for object
    my $Self = bless {%Param}, $Type;

    my $ParamObject = $Kernel::OM->Get('Kernel::System::Web::Request');

    # Try to load draft if requested.
    if (
        $Kernel::OM->Get('Kernel::Config')->Get("Ticket::Frontend::$Self->{Action}")->{FormDraft}
        && $ParamObject->GetParam( Param => 'LoadFormDraft' )
        && $ParamObject->GetParam( Param => 'FormDraftID' )
        )
    {
        $Self->{LoadedFormDraftID} = $ParamObject->LoadFormDraft(
            FormDraftID => $ParamObject->GetParam( Param => 'FormDraftID' ),
            UserID      => $Self->{UserID},
            ObjectID    => $ParamObject->GetParam( Param => 'TicketID' ),
        );
    }

    $Self->{Debug} = $Param{Debug} || 0;

    # frontend specific config
    my $Config = $Kernel::OM->Get('Kernel::Config')->Get("Ticket::Frontend::$Self->{Action}");

    my $Definition = $Kernel::OM->Get('Kernel::System::Ticket::Mask')->DefinitionGet(
        Mask => $Self->{Action},
    ) || {};

    $Self->{MaskDefinition} = $Definition->{Mask};

    # get form id
    $Self->{FormID} = $Kernel::OM->Get('Kernel::System::Web::FormCache')->PrepareFormID(
        ParamObject  => $Kernel::OM->Get('Kernel::System::Web::Request'),
        LayoutObject => $Kernel::OM->Get('Kernel::Output::HTML::Layout'),
    );

    return $Self;
}

sub Run {
    my ( $Self, %Param ) = @_;

    # get needed objects
    my $LayoutObject  = $Kernel::OM->Get('Kernel::Output::HTML::Layout');
    my $TicketObject  = $Kernel::OM->Get('Kernel::System::Ticket');
    my $ConfigObject  = $Kernel::OM->Get('Kernel::Config');
    my $ParamObject   = $Kernel::OM->Get('Kernel::System::Web::Request');

    # check needed stuff
    if ( !$Self->{TicketID} ) {
        return $LayoutObject->ErrorScreen(
            Message => Translatable('No TicketID is given!'),
            Comment => Translatable('Please contact the administrator.'),
        );
    }

    # get config of frontend module
    my $Config = $ConfigObject->Get("Ticket::Frontend::$Self->{Action}");

    # check permissions
    ACCESS:
    for my $AccessType (qw(rw ro)) {
        if (
            $TicketObject->TicketPermission(
                Type     => $AccessType,
                TicketID => $Self->{TicketID},
                UserID   => $Self->{UserID},
                LogNo    => 1,
            )
            )
        {
            $Self->{AccessMode} = $AccessType;

            last ACCESS;
        }
    }

    # error screen, don't show ticket
    if ( !$Self->{AccessMode} ) {
        return $LayoutObject->NoPermission(
            Message    => $LayoutObject->{LanguageObject}->Translate('You have no permissions!'),
            WithHeader => 'yes',
        );
    }

    # get ACL restrictions
    my %PossibleActions = ( 1 => $Self->{Action} );

    my $ACL = $TicketObject->TicketAcl(
        Data          => \%PossibleActions,
        Action        => $Self->{Action},
        TicketID      => $Self->{TicketID},
        ReturnType    => 'Action',
        ReturnSubType => '-',
        UserID        => $Self->{UserID},
    );
    my %AclAction = $TicketObject->TicketAclActionData();

    # check if ACL restrictions exist
    if ($ACL) {

        my %AclActionLookup = reverse %AclAction;

        # show error screen if ACL prohibits this action
        if ( !$AclActionLookup{ $Self->{Action} } ) {
            return $LayoutObject->NoPermission( WithHeader => 'yes' );
        }
    }

    # Check for failed draft loading request.
    if (
        $ParamObject->GetParam( Param => 'LoadFormDraft' )
        && !$Self->{LoadedFormDraftID}
        )
    {
        return $LayoutObject->ErrorScreen(
            Message => Translatable('Loading draft failed!'),
            Comment => Translatable('Please contact the administrator.'),
        );
    }

    my %Ticket = $TicketObject->TicketGet(
        TicketID      => $Self->{TicketID}
    );

    # get lock state
    my $TicketBackType = 'TicketBack';
    if ( $Config->{RequiredLock} ) {
        if ( !$TicketObject->TicketLockGet( TicketID => $Self->{TicketID} ) ) {

            my $Lock = $TicketObject->TicketLockSet(
                TicketID => $Self->{TicketID},
                Lock     => 'lock',
                UserID   => $Self->{UserID}
            );

            # Set new owner if ticket owner is different then logged user.
            if ( $Lock && ( $Ticket{OwnerID} != $Self->{UserID} ) ) {

                # Remember previous owner, which will be used to restore ticket owner on undo action.
                $Ticket{PreviousOwner} = $Ticket{OwnerID};

                my $Success = $TicketObject->TicketOwnerSet(
                    TicketID  => $Self->{TicketID},
                    UserID    => $Self->{UserID},
                    NewUserID => $Self->{UserID},
                );

                # Show lock state.
                if ( !$Success ) {
                    return $LayoutObject->FatalError();
                }
            }

            $TicketBackType .= 'Undo';
        }
    }

    print STDERR "**********************************\n";
    print STDERR $ParamObject->GetParam( Param => 'FormDraftID' );
    print STDERR "\n**********************************\n";
    # get params
    my %GetParam;
    #my $FormDraft = $Kernel::OM->Get('Kernel::System::FormDraft')->FormDraftGet(
    #    FormDraftID => $ParamObject->GetParam( Param => 'FormDraftID' ),
    #    ObjectID    => $Ticket{TicketID},
    #    UserID      => $Self->{UserID},
    #);
    for (
        qw(To Cc Bcc Subject Body FormDraftID Title)
        )
    {
        $GetParam{$_} = $ParamObject->GetParam( Param => $_ );
        #$GetParam{$_} = $FormDraft->{FormData}->{$_};
    }

    # Make sure sender is correct one. See bug#14872 ( https://bugs.otrs.org/show_bug.cgi?id=14872 ).
    $GetParam{From} = $Kernel::OM->Get('Kernel::System::TemplateGenerator')->Sender(
        QueueID => $Ticket{QueueID},
        UserID  => $Self->{UserID},
    );

    my $CustomersNumberTo = $ParamObject->GetParam( Param => 'CustomerTicketCounterToCustomer' ) || 0;

    # get check item object
    my $CheckItemObject = $Kernel::OM->Get('Kernel::System::CheckItem');

    if ($CustomersNumberTo) {
        my $CustomerCounter = 1;

        COUNT:
        for my $Count ( 1 .. $CustomersNumberTo ) {
            last COUNT if $Count > 1_000;    # bail out when the number of customers is abnormally high

            my $CustomerElement = $ParamObject->GetParam( Param => 'CustomerTicketText_' . $Count );

            next COUNT unless $CustomerElement;

            if ( $GetParam{To} ) {
                $GetParam{To} .= ', ' . $CustomerElement;
            }
            else {
                $GetParam{To} = $CustomerElement;
            }
        }
    }

    my $CustomersNumberCc = $ParamObject->GetParam( Param => 'CustomerTicketCounterCcCustomer' ) || 0;

    if ($CustomersNumberCc) {
        my $CustomerCounterCc = 1;

        COUNT:
        for my $Count ( 1 .. $CustomersNumberCc ) {
            last COUNT if $Count > 1_000;    # bail out when the number of customers is abnormally high

            my $CustomerElementCc = $ParamObject->GetParam( Param => 'CcCustomerTicketText_' . $Count );

            next COUNT unless $CustomerElementCc;

            if ( $GetParam{Cc} ) {
                $GetParam{Cc} .= ', ' . $CustomerElementCc;
            }
            else {
                $GetParam{Cc} = $CustomerElementCc;
            }
        }
    }

    my $CustomersNumberBcc = $ParamObject->GetParam( Param => 'CustomerTicketCounterBccCustomer' ) || 0;

    if ($CustomersNumberBcc) {
        my $CustomerCounterBcc = 1;

        COUNT:
        for my $Count ( 1 .. $CustomersNumberBcc ) {
            last COUNT if $Count > 1_000;    # bail out when the number of customers is abnormally high

            my $CustomerElementBcc = $ParamObject->GetParam( Param => 'BccCustomerTicketText_' . $Count );

            next COUNT unless $CustomerElementBcc;

            if ( $GetParam{Bcc} ) {
                $GetParam{Bcc} .= ', ' . $CustomerElementBcc;
            }
            else {
                $GetParam{Bcc} = $CustomerElementBcc;
            }
        }
    }

    # get upload cache object
    my $UploadCacheObject = $Kernel::OM->Get('Kernel::System::Web::UploadCache');

    # update
    if ( $Self->{Subaction} eq 'SendEmail' || $Self->{LoadedFormDraftID} ) {
        # challenge token check for write action
        if ( !$Self->{LoadedFormDraftID} ) {
            $LayoutObject->ChallengeTokenCheck();
        }

        # get valid state id
        if ( !$GetParam{StateID} ) {
            my %Ticket = $TicketObject->TicketGet(
                TicketID => $Self->{TicketID},
                UserID   => 1,
            );
            $GetParam{StateID} = $Ticket{StateID};
        }

        my %StateData = $Kernel::OM->Get('Kernel::System::State')->StateGet( ID => $GetParam{StateID} );

        my %Error;

        # get check item object
        my $CheckItemObject = $Kernel::OM->Get('Kernel::System::CheckItem');

        # get all attachments meta data
        my @Attachments = $UploadCacheObject->FormIDGetAllFilesMeta(
            FormID => $Self->{FormID},
        );

        # Get and validate draft action.
        my $FormDraftAction = $ParamObject->GetParam( Param => 'FormDraftAction' );
        if ( $FormDraftAction && !$Config->{FormDraft} ) {
            return $LayoutObject->ErrorScreen(
                Message => Translatable('FormDraft functionality disabled!'),
                Comment => Translatable('Please contact the administrator.'),
            );
        }

        my %FormDraftResponse;

        # Check draft name.
        if (
            $FormDraftAction
            &&
            ( $FormDraftAction eq 'Add' || $FormDraftAction eq 'Update' )
            )
        {
            my $Title = $ParamObject->GetParam( Param => 'FormDraftTitle' );

            # A draft name is required.
            if ( !$Title ) {

                %FormDraftResponse = (
                    Success      => 0,
                    ErrorMessage => $Kernel::OM->Get('Kernel::Language')->Translate("Draft name is required!"),
                );
            }

            # Chosen draft name must be unique.
            else {
                my $FormDraftList = $Kernel::OM->Get('Kernel::System::FormDraft')->FormDraftListGet(
                    ObjectType => 'Ticket',
                    ObjectID   => $Self->{TicketID},
                    Action     => $Self->{Action},
                    UserID     => $Self->{UserID},
                );
                DRAFT:
                for my $FormDraft ( @{$FormDraftList} ) {

                    # No existing draft with same name.
                    next DRAFT if $Title ne $FormDraft->{Title};

                    # Same name for update on existing draft.
                    if (
                        $GetParam{FormDraftID}
                        && $FormDraftAction eq 'Update'
                        && $GetParam{FormDraftID} eq $FormDraft->{FormDraftID}
                        )
                    {
                        next DRAFT;
                    }

                    # Another draft with the chosen name already exists.
                    %FormDraftResponse = (
                        Success      => 0,
                        ErrorMessage => $Kernel::OM->Get('Kernel::Language')->Translate( "FormDraft name %s is already in use!", $Title ),
                    );
                    last DRAFT;
                }
            }
        }

        # Perform draft action instead of saving form data in ticket/article.
        if ( $FormDraftAction && !%FormDraftResponse ) {

            # Reset FormDraftID to prevent updating existing draft.
            if ( $FormDraftAction eq 'Add' && $GetParam{FormDraftID} ) {

                # meddling with the innards of Kernel::System::Web::Request
                $ParamObject->SetArray(
                    Param  => 'FormDraftID',
                    Values => ['']
                );
            }

            my $FormDraftActionOk;
            if (
                $FormDraftAction eq 'Add'
                ||
                ( $FormDraftAction eq 'Update' && $GetParam{FormDraftID} )
                )
            {
                $FormDraftActionOk = $Self->_UpdateFormDraft(
                    UserID     => $Self->{UserID},
                    ObjectType => 'Ticket',
                    ObjectID   => $Self->{TicketID},
                );
            }
            elsif ( $FormDraftAction eq 'Delete' && $GetParam{FormDraftID} ) {
                $FormDraftActionOk = $Kernel::OM->Get('Kernel::System::FormDraft')->FormDraftDelete(
                    FormDraftID => $GetParam{FormDraftID},
                    UserID      => $Self->{UserID},
                );
            }

            if ($FormDraftActionOk) {
                $FormDraftResponse{Success} = 1;
            }
            else {
                %FormDraftResponse = (
                    Success      => 0,
                    ErrorMessage => 'Could not perform requested draft action!',
                );
            }
        }

        # Return JSON when there already is a response
        if (%FormDraftResponse) {

            # build JSON output
            my $JSON = $LayoutObject->JSONEncode(
                Data => \%FormDraftResponse,
            );

            # send JSON response
            return $LayoutObject->Attachment(
                ContentType => 'application/json',
                Content     => $JSON,
                Type        => 'inline',
                NoCache     => 1,
            );
        }

        # Make sure we don't save form if a draft was loaded.
        if ( $Self->{LoadedFormDraftID} ) {
            %Error = ( LoadedFormDraft => 1 );
        }

        # check errors
        if (%Error) {

            my $Output = $LayoutObject->Header(
                Value     => $Ticket{TicketNumber},
                Type      => 'Small',
                BodyClass => 'Popup',
            );

            # When a draft is loaded, inform a user that article subject will be empty
            # if contains only the ticket hook (if nothing is modified).
            if ( $Error{LoadedFormDraft} ) {
                $Output .= $LayoutObject->Notify(
                    Data => $LayoutObject->{LanguageObject}->Translate(
                        'Article subject will be empty if the subject contains only the ticket hook!'
                    ),
                );
            }

            $GetParam{StandardResponse} = $GetParam{Body};
            $Output .= $Self->_Mask(
                TicketID   => $Self->{TicketID},
                NextStates => $Self->_GetNextStates(
                    %GetParam,
                ),
                ResponseFormat      => $LayoutObject->Ascii2Html( Text => $GetParam{Body} ),
                Errors              => \%Error,
                Attachments         => \@Attachments,
                GetParam            => \%GetParam,
                TicketBackType      => $TicketBackType,
                %Ticket,
                %GetParam,
            );
            $Output .= $LayoutObject->Footer(
                Type => 'Small',
            );
            return $Output;
        }
    }
}

sub _GetNextStates {
    my ( $Self, %Param ) = @_;

    # get next states
    my %NextStates = $Kernel::OM->Get('Kernel::System::Ticket')->TicketStateList(
        %Param,
        Action   => $Self->{Action},
        TicketID => $Self->{TicketID},
        UserID   => $Self->{UserID},
    );
    return \%NextStates;
}

sub _Mask {
    my ( $Self, %Param ) = @_;

    # get needed objects
    my $LayoutObject = $Kernel::OM->Get('Kernel::Output::HTML::Layout');
    my $ConfigObject = $Kernel::OM->Get('Kernel::Config');

    # get config for frontend module
    my $Config = $ConfigObject->Get("Ticket::Frontend::$Self->{Action}");
    my $CustomerUserObject = $Kernel::OM->Get('Kernel::System::CustomerUser');

    $LayoutObject->Block(
        Name => $Param{TicketBackType},
        Data => {

            #            FormID => $Self->{FormID},
            %Param,
        },
    );

    # add rich text editor
    if ( $LayoutObject->{BrowserRichText} ) {

        # use height/width defined for this screen
        $Param{RichTextHeight} = $Config->{RichTextHeight} || 0;
        $Param{RichTextWidth}  = $Config->{RichTextWidth}  || 0;

        # set up rich text editor
        $LayoutObject->SetRichTextParameters(
            Data => \%Param,
        );
    }

    # show attachments
    ATTACHMENT:
    for my $Attachment ( @{ $Param{Attachments} } ) {
        if (
            $Attachment->{ContentID}
            && $LayoutObject->{BrowserRichText}
            && ( $Attachment->{ContentType} =~ /image/i )
            && ( $Attachment->{Disposition} eq 'inline' )
            )
        {
            next ATTACHMENT;
        }

        push @{ $Param{AttachmentList} }, $Attachment;
    }

    my $LoadedFormDraft;
    if ( $Self->{LoadedFormDraftID} ) {
        $LoadedFormDraft = $Kernel::OM->Get('Kernel::System::FormDraft')->FormDraftGet(
            FormDraftID => $Self->{LoadedFormDraftID},
            GetContent  => 0,
            ObjectID    => $Self->{TicketID},
            UserID      => $Self->{UserID},
        );

        my @Articles = $Kernel::OM->Get('Kernel::System::Ticket::Article')->ArticleList(
            TicketID => $Self->{TicketID},
            OnlyLast => 1,
        );

        if (@Articles) {
            my $LastArticle = $Articles[0];

            my $LastArticleSystemTime;
            if ( $LastArticle->{CreateTime} ) {
                my $LastArticleSystemTimeObject = $Kernel::OM->Create(
                    'Kernel::System::DateTime',
                    ObjectParams => {
                        String => $LastArticle->{CreateTime},
                    },
                );
                $LastArticleSystemTime = $LastArticleSystemTimeObject->ToEpoch();
            }

            my $FormDraftSystemTimeObject = $Kernel::OM->Create(
                'Kernel::System::DateTime',
                ObjectParams => {
                    String => $LoadedFormDraft->{ChangeTime},
                },
            );
            my $FormDraftSystemTime = $FormDraftSystemTimeObject->ToEpoch();

            if ( !$LastArticleSystemTime || $FormDraftSystemTime <= $LastArticleSystemTime ) {
                $Param{FormDraftOutdated} = 1;
            }
        }
    }

    if ( IsHashRefWithData($LoadedFormDraft) ) {

        $LoadedFormDraft->{ChangeByName} = $Kernel::OM->Get('Kernel::System::User')->UserName(
            UserID => $LoadedFormDraft->{ChangeBy},
        );
    }

    # explanatory message about asterisk
    if ( $ConfigObject->Get('Ticket::Frontend::AsteriskExplanation') ) {
        $LayoutObject->Block(
            Name => 'AsteriskExplanation',
        );
    }

    if ( $Self->{AccessMode} ne "rw" ) {
        $Param{ReadOnly}      = 'readonly';
        $Param{ReadOnlyClass} = 'Readonly';
    }

    $LayoutObject->Block(
        Name => 'ToCustomer',
        Data => {
            ToCustomer => $Param{GetParam}{To}
        }
    );
    $LayoutObject->Block(
        Name => 'CcCustomer',
        Data => {
            Cc => $Param{GetParam}{Cc}
        }
    );
    $LayoutObject->Block(
        Name => 'BccCustomer',
        Data => {
            Bcc => $Param{GetParam}{Bcc}
        }
    );

    # create & return output
    return $LayoutObject->Output(
        TemplateFile => 'AgentTicketFormDraftEdit',
        Data         => {
            FormID         => $Self->{FormID},
            FormDraft      => $Config->{FormDraft},
            FormDraftID    => $Self->{LoadedFormDraftID},
            FormDraftTitle => $LoadedFormDraft ? $LoadedFormDraft->{Title} : '',
            FormDraftMeta  => $LoadedFormDraft,
            %Param,
        },
    );
}

sub _UpdateFormDraft {
    my ( $Self, %Param ) = @_;

    # check params
    return if !$Param{UserID} || !$Param{ObjectType} || !IsInteger( $Param{ObjectID} );

    # create necessary objects
    my $ParamObject     = $Kernel::OM->Get('Kernel::System::Web::Request');
    my $DraftFormObject = $Kernel::OM->Get('Kernel::System::FormDraft');

    # gather necessary data for backend
    my %MetaParams;
    for my $Param (qw(Action FormDraftID FormDraftTitle FormID)) {
        $MetaParams{$Param} = $ParamObject->GetParam(
            Param => $Param,
        );
    }
    return unless $MetaParams{Action};

    # determine session name param (SessionUseCookie = 0) for exclusion
    my $SessionName = $Kernel::OM->Get('Kernel::Config')->Get('SessionName') || 'SessionID';

    # compile override list
    my %OverrideParams = IsHashRefWithData( $Param{OverrideParams} ) ? %{ $Param{OverrideParams} } : ();

    # these params must always be excluded for safety, they take precedence
    for my $Name (
        qw(Action ChallengeToken FormID FormDraftID FormDraftTitle FormDraftAction LoadFormDraftID),
        $SessionName
        )
    {
        $OverrideParams{$Name} = undef;
    }

    # Gather all params.
    #   Exclude, add or override by using OverrideParams if necessary.
    my @ParamNames = $ParamObject->GetParamNames();
    my %ParamSeen;

    my $FormDraft = ($DraftFormObject)->FormDraftGet(
        FormDraftID => $MetaParams{FormDraftID},
        ObjectID    => $Param{ObjectID},
        UserID      => $Param{UserID},
    );
    my %FormData = $FormDraft->{FormData}->%*;

    PARAM:
    for my $Param ( @ParamNames, sort keys %OverrideParams ) {

        next PARAM if $ParamSeen{$Param}++;
        my $Value;

        # check for overrides first
        if ( exists $OverrideParams{$Param} ) {

            # allow only strings and array references as value
            if (
                IsStringWithData( $OverrideParams{$Param} )
                || IsArrayRefWithData( $OverrideParams{$Param} )
                )
            {
                $Value = $OverrideParams{$Param};
            }

            # skip all other parameters (including those specified to be excluded by using 'undef')
            else {
                next PARAM;
            }
        }

        # get other values from param object
        if ( !defined $Value ) {
            my @Values = $ParamObject->GetArray( Param => $Param );
            next PARAM unless IsArrayRefWithData( \@Values );

            # store single occurances as string
            if ( scalar @Values == 1 ) {
                $Value = $Values[0];
            }

            # store multiple occurances as array reference
            else {
                $Value = \@Values;
            }
        }

        $FormData{$Param} = $Value;
    }

    # get files from upload cache
    my @FileData = $Kernel::OM->Get('Kernel::System::Web::UploadCache')->FormIDGetAllFilesData(
        FormID => $MetaParams{FormID},
    );

    use Data::Dumper;
    print STDERR Dumper $FormDraft;
    # prepare data to add or update draft
    my %FormDraft = (
        FormData    => \%FormData,
        FileData    => \@FileData,
        FormDraftID => $MetaParams{FormDraftID},
        ObjectType  => $Param{ObjectType},
        ObjectID    => $Param{ObjectID},
        Action      => $FormDraft->{Action},
        Title       => $MetaParams{FormDraftTitle},
        UserID      => $Param{UserID},
    );

    # update draft
    if ( $MetaParams{FormDraftID} ) {
        return unless $DraftFormObject->FormDraftUpdate(%FormDraft);
        return 1;
    }

    # create new draft
    return unless $DraftFormObject->FormDraftAdd(%FormDraft);
    return 1;
}

1;
