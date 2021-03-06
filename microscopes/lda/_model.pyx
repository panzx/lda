# cython: embedsignature=True
import itertools
import numpy as np
import warnings

from microscopes.common import validator
from copy import deepcopy
from itertools import chain
from collections import Counter

from microscopes.lda import utils
from microscopes.io.schema_pb2 import LdaModelState

def deprecated(func):
    """This is a decorator which can be used to mark functions
    as deprecated. It will result in a warning being emmitted
    when the function is used."""
    def new_func(*args, **kwargs):
        warnings.simplefilter('always', DeprecationWarning) #turn off filter
        warnings.warn("Call to deprecated function {}.".format(func.__name__), category=DeprecationWarning, stacklevel=2)
        warnings.simplefilter('default', DeprecationWarning) #reset filter
        return func(*args, **kwargs)
    return new_func


DEFAULT_INITIAL_DISH_HINT = 10


cdef class state:
    """The underlying state of an HDP-LDA
    You should not explicitly construct a state object.
    Instead, use :func:`initialize`.
    Notes
    -----
    This class is not meant to be sub-classed.
    """
    def __cinit__(self, model_definition defn,
                  vector[vector[size_t]] data,
                  vocab, **kwargs):
        # Save and validate model definition
        self._defn = defn
        self._vocab = vocab
        self._data = data
        validator.validate_len(data, defn.n, "data")

        for doc in data:
            for word in doc:
                if word >= defn.v:
                    raise ValueError("Word index out of bounds.")

        # Validate kwargs
        valid_kwargs = ('r', 'dish_hps', 'vocab_hp',
                        'initial_dishes',
                        'topic_assignments',
                        'dish_assignments',
                        'table_assignments',)
        validator.validate_kwargs(kwargs, valid_kwargs)

        # Save and validate hyperparameters
        dish_hps = kwargs.get('dish_hps', None)
        if dish_hps is None:
            dish_hps = {'alpha': 0.1, 'gamma': 0.1}
        validator.validate_kwargs(dish_hps, ('alpha', 'gamma',))

        vocab_hp = kwargs.get('vocab_hp', 0.5)
        validator.validate_positive(vocab_hp)

        # Get initial dishes or assigments
        dishes_and_tables = _get_dishes_and_tables(kwargs, data)

        if 'initial_dishes' in dishes_and_tables:
            self._thisptr = c_initialize(
                defn=defn._thisptr.get()[0],
                alpha=dish_hps['alpha'],
                beta=vocab_hp,
                gamma=dish_hps['gamma'],
                initial_dishes=dishes_and_tables['initial_dishes'],
                docs=data,
                rng=(<rng> kwargs['r']  )._thisptr[0])
        elif "table_assignments" in dishes_and_tables \
                and "dish_assignments" in dishes_and_tables:

            self._thisptr = c_initialize_explicit(
                defn=defn._thisptr.get()[0],
                alpha=dish_hps['alpha'],
                beta=vocab_hp,
                gamma=dish_hps['gamma'],
                dish_assignments=dishes_and_tables['dish_assignments'],
                table_assignments=dishes_and_tables['table_assignments'],
                docs=data)
        else:
            raise NotImplementedError(("Specify either: (1) initial_dishes or"
                "(2) table_assignments and dish_assignments."))

    property gamma:
        def __get__(self): return self._thisptr.get().gamma_
        def __set__(self, gamma): self._thisptr.get().gamma_ = gamma

    property alpha:
        def __get__(self): return self._thisptr.get().alpha_
        def __set__(self, alpha): self._thisptr.get().alpha_ = alpha

    property beta:
        def __get__(self): return self._thisptr.get().beta_
        def __set__(self, beta): self._thisptr.get().beta_ = beta

    def perplexity(self):
        return self._thisptr.get().perplexity()

    def nentities(self):
        """Get number of entities/documents in model.
        """
        return self._thisptr.get().nentities()

    def ntopics(self):
        """Get number of topics in current state
        """
        return self._thisptr.get().ntopics()

    def nwords(self):
        """Get number of unique words in all documents
        """
        return self._thisptr.get().nwords()

    def active_topics(self):
        """Get indices of active topics
        """
        dishes = list(self._thisptr.get().dishes())
        dishes.remove(0) # remove dummy topic
        return dishes

    def assignments(self):
        """Get list of lists mapping words in documents to topic.
        """
        return self._thisptr.get()[0].assignments()

    def dish_assignments(self):
        """List of lists that maps tables to dishes.
        Outer length is number of documents. Inner lists maps
        tables for each document to dish indices.
        """
        return self._thisptr.get()[0].dish_assignments()

    def table_assignments(self):
        """Returns a list of lists that maps words to tables.
        Integer valued. Same shape as documents.
        """
        return self._thisptr.get()[0].table_assignments()

    def tables(self, size_t eid):
        return self._thisptr.get()[0].tables(eid)

    def n_k(self, size_t tid):
        """Number of words assigned to each dish plus beta * V
        """
        return self._thisptr.get()[0].num_words_at_dish(tid)

    def n_kv(self, size_t tid, size_t word_id):
        """Number of times a given word is assigned to each dish plus beta
        """
        return self._thisptr.get()[0].num_words_at_dish(tid, word_id)

    @deprecated
    def document_distribution(self):
        return self.topic_distribution_by_document()

    def topic_distribution_by_document(self):
        """Return list of distributions over topics for each document.

        Return value is a list of lists. Each entry in the outer list corresponds
        to a document. Each value in the each inner list is the probability of that
        topic being generated in this document.

        Commonly called Theta in the probablistic topic modeling literature.
        """
        doc_distribution = self._thisptr.get()[0].document_distribution()
        # Remove dummy topic
        distributions = [topic_distribution[1:] for topic_distribution in doc_distribution]
        # Normalize
        distributions = [[i/sum(d) for i in d] for d in distributions]
        return distributions

    @deprecated
    def word_distribution(self, rng r=None):
        return self.word_distribution_by_topic()

    def word_distribution_by_topic(self):
        """Return distribution over vocabulary words for each topic.

        Return value is a list of dictionaries. Each entry in the list corresponds
        to a topic. Each dictionary maps from the full vocabulary to the probability
        of the term being generated by that topic.

        Commoly called Phi in the probablistic topic modeling literature.
        """
        num_distribution_by_topic = self._thisptr.get()[0].word_distribution()
        # C++ returns a list of maps from integer representation of terms to
        # probabilities. Return the Python user a list of maps from the original
        # words (hashable objects) to probabilities.
        word_distribution_by_topic = []
        for num_dist in num_distribution_by_topic:
            word_dist = {}
            for num, prob in num_dist.iteritems():
                word = self._vocab[num]
                word_dist[word] = prob
            word_distribution_by_topic.append(word_dist)
        return word_distribution_by_topic


    def serialize(self):
        """Serialize state object as a string
        """
        if not self._can_serialize():
            raise ValueError("Can only serialize model if all words are strings.")
        proto_lda = LdaModelState()
        flat, indices = utils.ragged_array_to_row_major_form(self._data)
        proto_lda.docs.extend(flat)
        proto_lda.doc_index.extend(indices)
        proto_lda.alpha = self.alpha
        proto_lda.beta = self.beta
        proto_lda.gamma = self.gamma
        flat, indices = utils.ragged_array_to_row_major_form(self.table_assignments())
        proto_lda.table_assignment.extend(flat)
        proto_lda.table_assignment_index.extend(indices)
        flat, indices = utils.ragged_array_to_row_major_form(self.dish_assignments())
        proto_lda.dish_assignment.extend(flat)
        proto_lda.dish_assignment_index.extend(indices)
        proto_lda.vocab.extend([word for _, word in sorted(self._vocab.items())])
        return proto_lda.SerializeToString()

    def _can_serialize(self):
        return all(isinstance(word, str) for word in self._vocab.values())

    def __reduce__(self):
        return (_reconstruct_state, (self._defn, self.serialize()))

    def pyldavis_data(self, rng r=None):
        """Return dict of data required for visualization initialize
        in PyLDAvis (https://github.com/bmabey/pyLDAvis).


        Construct visualization with:

            pyLDAvis.prepare(**state.pyldavis_data())

        """
        sorted_num_vocab = sorted(self._vocab.keys())

        topic_term_distribution = []
        for topic in self.word_distribution_by_topic():
            t = [topic[self._vocab[word_id]]
                 for word_id in sorted_num_vocab]
            topic_term_distribution.append(t)

        doc_topic_distribution = self.topic_distribution_by_document()

        doc_lengths = [len(doc) for doc in self._data]
        vocab = [self._vocab[k] for k in sorted_num_vocab]

        ctr = self._corpus_term_id_frequency()
        term_frequency = [ctr[num] for num in sorted_num_vocab]

        return {'topic_term_dists': topic_term_distribution,
                'doc_topic_dists': doc_topic_distribution,
                'doc_lengths': doc_lengths,
                'vocab': vocab,
                'term_frequency': term_frequency}

    def _corpus_term_id_frequency(self):
        flatten = lambda l: list(itertools.chain.from_iterable(l))
        ctr = Counter(flatten(self._data))
        return ctr

    def _corpus_term_frequency(self):
        flatten = lambda l: list(itertools.chain.from_iterable(l))
        flat_data = flatten(self._data)
        flat_vocab = [self._vocab[tid] for tid in flat_data]
        ctr = Counter(flat_vocab)
        return ctr

    def term_relevance_by_topic(self, weight=0.5):
        """For each topic, get terms sorted by relevance.

        Relevance metric is defined by Sievert and Shirley (2004).
        It is a weighted average of the log probability of a word
        occurring in a topic and the log lift of assigning the word
        to the topic.
        """
        phi = self.word_distribution_by_topic()
        ctf = self._corpus_term_frequency()
        relevance_by_topic = []
        for word_dist in phi:
            term_relevance = []
            for term, phi_kw in word_dist.iteritems():
                p_w = ctf[term]
                rel = self._relevance_for_word(phi_kw, p_w, weight)
                term_relevance.append((term, rel))
            term_relevance_s = sorted(term_relevance, key=lambda r: r[1], reverse=True)
            relevance_by_topic.append(term_relevance_s)
        return relevance_by_topic

    def _relevance_for_word(self, phi_kw, p_w, weight=0.5):
        """Defined in LDAvis: A method for visualizing and interpreting topics (2014)
        by Sievert and Shirley
        """
        return weight * np.log(phi_kw) + \
            (1 - weight) * np.log(phi_kw / p_w)


    def predict(self, data, prng=None, max_iter=20, tol=1e-16):
        """Predict topic distributions for documents

        Based on ariddell's implementation of the iterated pseudo-counts
        method in Wallach et al. (2009).

        cf. https://github.com/ariddell/lda/blob/055f12ed76ac33c43e26b22060e0c6435487eeb7/lda/lda.py#L180-L210

        Parameters
        ----------
        data : document or list of documents
        max_iter : int, optional
            Maximum number of iterations.
        tol: double, optional
            Tolerance value used for stopping
        Returns
        -------
        list of topic distributions for each input document
        """
        if not isinstance(data[0], list):
            data = [data]
        return [self._predict_single(doc, max_iter, tol) for doc in data]

    def _predict_single(self, doc, max_iter, tol):
        PZS = np.zeros((len(doc), self.ntopics()))
        word_dist = self.word_distribution_by_topic()
        for iteration in range(max_iter + 1): # +1 is for initialization
            PZS_new = [[d[word] for d in word_dist]
                        for word in doc]
            PZS_new = np.array(PZS_new)
            PZS_new *= (PZS.sum(axis=0) - PZS + self.beta)
            PZS_new /= PZS_new.sum(axis=1)[:, np.newaxis] # vector to single column matrix
            PZS = PZS_new
            if np.abs(PZS_new - PZS).sum() < tol:
                break
        theta_doc = PZS.sum(axis=0) / PZS.sum()
        assert theta_doc.shape == (self.ntopics(),)
        return theta_doc.tolist()

def _get_dishes_and_tables(kwargs, data):
    """Extract parameters from kwargs
    """
    if "initial_dishes" in kwargs \
            and "table_assignments" not in kwargs \
            and "dish_assignments" not in kwargs:
        return {'initial_dishes': kwargs["initial_dishes"]}

    elif "table_assignments" in kwargs \
            and "dish_assignments" in kwargs \
            and "initial_dishes" not in kwargs:
        _validate_table_dish_assignment(kwargs['table_assignments'],
                                        kwargs['dish_assignments'],
                                        data)
        return {'table_assignments': kwargs['table_assignments'],
                'dish_assignments': kwargs['dish_assignments']}

    else:
        return {'initial_dishes': DEFAULT_INITIAL_DISH_HINT}


def _validate_table_dish_assignment(table_assignments, dish_assignments, data):
    """Ensure dish and table assignments are valid.
    """
    validator.validate_len(table_assignments, len(data), "table_assignments")
    validator.validate_len(dish_assignments, len(data), "dish_assignments")

    num_tables = []
    for table_assignment, doc in zip(table_assignments, data):
        validator.validate_len(table_assignment, len(doc), "table_assignment")
        num_tables.append(max(table_assignment))
    for dish_assignment, num_table in zip(dish_assignments, num_tables):
        validator.validate_len(dish_assignment, num_table+1, "dish_assignment")


def initialize(model_definition defn, data, r=None, **kwargs):
    """Initialize state to a random, valid point in the state space

    You should specify either dish_assignments and table_assignments ("explicit assignment")
    along with the vocab_lookup OR initial_dishes and random state `r`
    ("random assignment"), OR simply the random state. The hyperparameters can be
    specified or will default to the indicated values.

    Parameters
    ----------
    defn : model definition object
    data : a list of list of serializable objects (i.e. 'documents')
    r : random state (required if specifying initial_dishes
    initial_dishes: maximum number of dishes (topics) for random state initialization (default: 10)
    vocab_hp : parameter on symmetric Dirichlet prior over topic distributions ("beta") (default: 0.5)
    dish_hps : dict specifying concentration parameters on base ("alpha") (default: 0.1)
        and second-level ("gamma") Dirichlet processes (default: 0.1)
    table_assignments : list of lists that maps words to tables.
        Integer valued. Must be same shape as `data`.
    dish_assignments : list of lists that maps tables to dishes.
        Outer length should be the the same as `data`. Inner lists maps
        unique tables for each document to dish indices. Thus
        `len(dish_assignments[i]) == max(table_assignments[i]) + 1`
    vocab_lookup : dict mapping word index values (in data) to actual terms

    Example table and dish assignments:

        table_assignments=[[1, 2, 1, 2], [1, 1, 1], [3, 3, 3, 1]]
        dish_assignments=[[0, 1, 2], [0, 3], [0, 1, 2, 1]]

    Example

    Returns an LDA state object.
    """
    if r is not None:
        kwargs['r'] = r
    if 'vocab_lookup' in kwargs:
        vocab_lookup = kwargs['vocab_lookup']
        del kwargs['vocab_lookup']
        if not all(isinstance(word, (int, long)) for doc in data for word in doc):
            raise ValueError("Docs must be numeric when vocab_lookup is specified")
        numeric_docs = data
    else:
        numeric_docs, vocab_lookup = _initialize_data(data)
    validator.validate_len(vocab_lookup, defn.v, "vocab_lookup")
    return state(defn=defn, data=numeric_docs, vocab=vocab_lookup, **kwargs)

def _initialize_data(docs):
    """Convert docs (list of list of hashable items) to list of list of
    positive integers and a map from the integers back to the terms
    """
    vocab = set(chain.from_iterable(docs))
    word_to_int = { word: i for i, word in enumerate(vocab)}
    int_to_word = { i: word for i, word in enumerate(vocab)}
    numeric_docs = []
    for doc in docs:
        numeric_docs.append([word_to_int[word] for word in doc])
    return numeric_docs, int_to_word


def deserialize(model_definition defn, bytes):
    """Restore a state object from a bytestring representation.

    Note that a serialized representation of a state object does
    not contain its own structural definition.

    Parameters
    ----------
    defn : model definition
    bytes : bytestring representation of state genreated by state.serialize()
    """
    m = LdaModelState()
    m.ParseFromString(bytes)
    to_row_major = utils.row_major_form_to_ragged_array
    docs = to_row_major(m.docs, m.doc_index)
    table_assignments = to_row_major(m.table_assignment, m.table_assignment_index)
    dish_assignments = to_row_major(m.dish_assignment, m.dish_assignment_index)
    alpha = m.alpha
    beta = m.beta
    gamma = m.gamma
    vocab = {i: str(word) for i, word in enumerate(m.vocab)}
    s = initialize(defn, docs,
                   table_assignments=table_assignments,
                   dish_assignments=dish_assignments,
                   vocab_lookup=vocab,
                   dish_hps={'alpha': alpha, 'gamma': gamma}, vocab_hp=beta)
    return s


def _reconstruct_state(defn, bytes):
    return deserialize(defn, bytes)
