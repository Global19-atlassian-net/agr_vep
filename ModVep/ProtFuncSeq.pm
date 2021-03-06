=head1 NAME

ProtFuncSeq

=head1 SYNOPSIS

 mv ProtFuncSeq.pm ~/.vep/Plugins
 ./vep -i variations.vcf --plugin ProtFuncSeq,mod=MOD,pass=pword

=head1

 A VEP plugin that adds protein function annotation from SIFT and PolyPhen2
 and wild-type and variant protein sequences

=cut

package ProtFuncSeq;

use strict;
use warnings;

use Bio::EnsEMBL::Variation::ProteinFunctionPredictionMatrix qw($AA_LOOKUP);
use Bio::Seq;
use DBI;
use Digest::MD5 qw(md5_hex);

use base qw(Bio::EnsEMBL::Variation::Utils::BaseVepPlugin);

my %INCLUDE_SO = map {$_ => 1} qw(missense_variant stop_lost stop_gained start_lost);


sub new {
    my $class = shift;

    my $self = $class->SUPER::new(@_);
    my $param_hash = $self->params_to_hash();

    my $mod = $param_hash->{mod};
    my $db = 'agr_pathogenicity_predictions_' . $mod;
    my $host = $ENV{'WORM_DBHOST'};
    my $user = $ENV{'WORM_DBUSER'};
    my $port = $ENV{'WORM_DBPORT'};
    $self->{pass} = $param_hash->{'pass'};

    my $query = qq{
        SELECT t.translation_md5, a.analysis, p.prediction_matrix
            FROM translation_md5 t
            INNER JOIN protein_function_prediction p
                ON t.translation_md5_id = p.translation_md5_id
            INNER JOIN analysis a
                ON a.analysis_id = p.analysis_id
            WHERE t.translation_md5 = ?
    };

    $self->{dsn} = 'dbi:mysql:database=' . $db . ';host=' . $host . ';port=' . $port;
    $self->{user} = $user;
    $self->{dbh} ||= DBI->connect($self->{dsn}, $user, $self->{pass}) or die $DBI::errstr;
    $self->{get_sth} = $self->{dbh}->prepare($query);

    $self->{initial_pid} = $$;

    return $self;
}

sub get_header_info {
    my $self = shift;

    return {
	SIFT => 'SIFT prediction and score from ProtFuncAnnot plugin',
	PolyPhen => 'PolyPhen-2 HumDiv prediction and score from ProtFuncAnnot plugin',
	WtSeq => 'Wild-type translated amino acid sequence',
	VarSeq => 'Variant translated amino acid sequence'
    };
}
	

sub feature_types {
    return ['Transcript'];
}

sub variant_feature_types {
    return ['VariationFeature'];
}


sub run {
    my ($self, $tva) = @_;

    my $results = {};
    
    my $tr = $tva->transcript;
    my $tv = $tva->transcript_variation;

    my $tr_vep_cache = $tr->{_variation_effect_feature_cache} || {}; 

    unless ($tr_vep_cache->{peptide}) {
	my $translation = $tr->translate;
	return $results unless $translation;
	$tr_vep_cache->{peptide} = $translation->seq;
    }
    
    $results->{'WtSeq'} = $tr_vep_cache->{peptide};

    if ($tva->peptide and $tv->translation_start and $tv->translation_end) {
	my $tl_start = $tv->translation_start;
	my $tl_end = $tv->translation_end;

	my $var_translation = $results->{'WtSeq'};
	if ($tva->peptide =~ /X$/) {
	    substr($var_translation, $tl_start - 1) = $tva->peptide;
	}
	else {
	    substr($var_translation, $tl_start - 1, $tl_end - $tl_start + 1) = $tva->peptide;
	}
	$results->{'VarSeq'} = $var_translation;
    }

    return $results unless grep {$INCLUDE_SO{$_->SO_term}} @{$tva->get_all_OverlapConsequences};
    return $results unless $tva->variation_feature->{start} eq $tva->variation_feature->{end};
    
    return $results unless defined $AA_LOOKUP->{$tva->peptide} and $tv->translation_start == $tv->translation_end;
   
    
    # get data, indexed on md5 of peptide sequence
    my $md5 = md5_hex($tr_vep_cache->{peptide});
    my $data = $self->fetch_from_cache($md5);

    unless ($data) {
        # forked, reconnect to DB
	if($$ != $self->{initial_pid}) {
	    $self->{dbh} = DBI->connect($self->{dsn},$self->{user},$self->{pass});
	    my $query = qq{
                SELECT t.translation_md5, a.analysis, p.prediction_matrix
                    FROM translation_md5 t
                INNER JOIN protein_function_prediction p
                    ON t.translation_md5_id = p.translation_md5_id
                INNER JOIN analysis a
                    ON a.analysis_id = p.analysis_id
                WHERE t.translation_md5 = ?
            };
	    $self->{get_sth} = $self->{dbh}->prepare($query);
		
	    # set this so only do once per fork
	    $self->{initial_pid} = $$;
	}
	
	$self->{get_sth}->execute($md5);

	$data = {};
	while(my $arrayref = $self->{get_sth}->fetchrow_arrayref) {
	    my $analysis = $arrayref->[1] eq 'pph' ? 'polyphen' : $arrayref->[1];
	    my $sub_analysis;
	    $sub_analysis = 'humdiv' if $analysis eq 'polyphen';
	    $data->{$analysis} = Bio::EnsEMBL::Variation::ProteinFunctionPredictionMatrix->new(
		-translation_md5    => $arrayref->[0],
		-analysis           => $analysis,
		-sub_analysis       => $sub_analysis,
		-matrix             => $arrayref->[2]
		);
	}
	$self->add_to_cache($md5, $data);
    }

    $tr_vep_cache->{protein_function_predictions} = $data;

    foreach my $tool_string(qw(SIFT PolyPhen)) {
	my $analysis = lc($tool_string);
	next unless exists $data->{$analysis};
	my ($pred, $score) = $data->{$analysis}->get_prediction($tv->translation_start, $tva->peptide);
	if($pred) {
	    $pred =~ s/\s+/\_/g;
	    $pred =~ s/\_\-\_/\_/g;
	    $results->{$tool_string} = $pred . '(' . $score . ')';
	}
    }    
   
    return $results;
}

sub fetch_from_cache {
    my ($self, $md5) = @_;

    my $cache = $self->{_cache} ||= [];
    my ($data) = map {$_->{data}} grep {$_->{md5} eq $md5} @$cache;

    return $data;
}

sub add_to_cache {
    my ($self, $md5, $data) = @_;

    my $cache = $self->{_cache} ||= [];
    push @$cache, {md5 => $md5, data => $data};

    shift @$cache while scalar @$cache > 50;

    return;
}

1;


