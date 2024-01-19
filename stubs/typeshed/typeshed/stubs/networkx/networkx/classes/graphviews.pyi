from collections.abc import Callable, Hashable
from typing import TypeVar, overload

from networkx.classes.digraph import DiGraph
from networkx.classes.graph import Graph, _Node
from networkx.classes.multidigraph import MultiDiGraph
from networkx.classes.multigraph import MultiGraph

_G = TypeVar("_G", bound=Graph[Hashable])
_D = TypeVar("_D", bound=DiGraph[Hashable])

@overload
def generic_graph_view(G: _G, create_using: None = None) -> _G: ...
@overload
def generic_graph_view(G: Graph[_Node], create_using: type[MultiDiGraph[_Node]]) -> MultiDiGraph[_Node]: ...
@overload
def generic_graph_view(G: Graph[_Node], create_using: type[DiGraph[_Node]]) -> DiGraph[_Node]: ...
@overload
def generic_graph_view(G: Graph[_Node], create_using: type[MultiGraph[_Node]]) -> MultiGraph[_Node]: ...
@overload
def generic_graph_view(G: Graph[_Node], create_using: type[Graph[_Node]]) -> Graph[_Node]: ...
@overload
def subgraph_view(
    G: MultiDiGraph[_Node], filter_node: Callable[[_Node], bool] = ..., filter_edge: Callable[[_Node, _Node, int], bool] = ...
) -> MultiDiGraph[_Node]: ...
@overload
def subgraph_view(
    G: MultiGraph[_Node], filter_node: Callable[[_Node], bool] = ..., filter_edge: Callable[[_Node, _Node, int], bool] = ...
) -> MultiGraph[_Node]: ...
@overload
def subgraph_view(
    G: DiGraph[_Node], filter_node: Callable[[_Node], bool] = ..., filter_edge: Callable[[_Node, _Node], bool] = ...
) -> DiGraph[_Node]: ...
@overload
def subgraph_view(
    G: Graph[_Node], filter_node: Callable[[_Node], bool] = ..., filter_edge: Callable[[_Node, _Node], bool] = ...
) -> Graph[_Node]: ...
def reverse_view(G: _D) -> _D: ...
